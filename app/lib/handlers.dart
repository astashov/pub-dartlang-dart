// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_dartlang_org.handlers;

import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:appengine/appengine.dart';
import 'package:logging/logging.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;

import 'package:pub_dartlang_org/backend.dart';

import 'atom_feed.dart';
import 'handlers_redirects.dart';
import 'search_service.dart';
import 'models.dart';
import 'templates.dart';

Logger _logger = new Logger('pub.handlers');

/// Handler for the whole URL space of pub.dartlang.org
///
/// The passed in [shelfPubApi] handler will be used for handling requests to
///   - /api/*
Future<shelf.Response> appHandler(
    shelf.Request request, shelf.Handler shelfPubApi) async {
  var path = request.url.path;

  var handler = {
      '/' : indexHandler,
      '/feed.atom' : atomFeedHandler,
      '/authorized' : authorizedHandler,
      '/site-map' : sitemapHandler,
      '/admin' : adminHandler,
      '/search' : searchHandler,
      '/packages' : packagesHandler,
      '/packages.json' : packagesHandler,
  }[path];

  if (handler != null) {
    return handler(request);
  } else if (path == '/api/packages') {
    // NOTE: This is special-cased, since it is not an API used by pub but
    // rather by the editor.
    return apiPackagesHandler(request);
  } else if (path.startsWith('/api') ||
             path.startsWith('/packages') && path.endsWith('.tar.gz')) {
    return shelfPubApi(request);
  } else if (path.startsWith('/packages/')) {
    return packageHandler(request);
  } else if (path.startsWith('/doc')) {
    return docHandler(request);
  } else {
    return _notFoundHandler(request);
  }
}

/// Handles requests for /
indexHandler(_) async {
  var versions = await backend.latestPackageVersions(limit: 5);
  assert(!versions.any((version) => version == null));
  return _htmlResponse(templateService.renderIndexPage(versions));
}

/// Handles requests for /feed.atom
atomFeedHandler(shelf.Request request) async {
  final int PageSize = 10;

  // The python version had paging support, but there was no point to it, since
  // the "next page" link was never returned to the caller.
  int page = 1;

  var versions = await backend.latestPackageVersions(
      offset: PageSize * (page - 1), limit: PageSize);
  var feed = feedFromPackageVersions(request.requestedUri,  versions);
  return _atomXmlResponse(feed.toXmlDocument());
}

/// Handles requests for /authorized
authorizedHandler(_) => _htmlResponse(templateService.renderAuthorizedPage());

/// Handles requests for /doc
shelf.Response docHandler(shelf.Request request) {
  var pubDocUrl = 'https://www.dartlang.org/tools/pub/';
  var dartlangDotOrgPath = REDIRECT_PATHS[request.url.path];
  if (dartlangDotOrgPath != null) {
    return _redirectResponse('$pubDocUrl$dartlangDotOrgPath');
  }
  return _redirectResponse(pubDocUrl);
}

/// Handles requests for /site-map
sitemapHandler(_) => _htmlResponse(templateService.renderSitemapPage());

/// Handles requests for /admin
adminHandler(shelf.Request request) async {
  var users = userService;

  if (users.currentUser == null) {
    return _redirectResponse(await users.createLoginUrl('${request.url}'));
  } else {
    var email = users.currentUser.email;
    var isNonGoogleUser = !email.endsWith('@google.com');
    if (isNonGoogleUser) {
      var status = 'Unauthorized';
      var message = 'You do not have access to this page.';
      return _htmlResponse(
          templateService.renderErrorPage(status, message, null), status: 403);
    } else {
      var status = 'Not found.';
      var message = 'The admin page has been disabled.';
      return _htmlResponse(
          templateService.renderErrorPage(status, message, null), status: 404);
    }
  }
}

/// Handles requests for /search
searchHandler(shelf.Request request) async {
  var query = request.url.queryParameters['q'];
  if (query == null) {
    return _htmlResponse(templateService.renderSearchPage(
        query, [], new SearchLinks.empty('')));
  }

  int page = _pageFromUrl(
      request.url, maxPages: SEARCH_MAX_RESULTS ~/ PageLinks.RESULTS_PER_PAGE);

  int offset = PageLinks.RESULTS_PER_PAGE * (page - 1);
  int resultCount = PageLinks.RESULTS_PER_PAGE;
  var searchPage = await searchService.search(query, offset, resultCount);
  var links = new SearchLinks(query, searchPage.offset, searchPage.totalCount);
  return _htmlResponse(templateService.renderSearchPage(
      query, searchPage.packageVersions, links));
}

/// Handles requests for /packages - multiplexes to JSON/HTML handler.
packagesHandler(shelf.Request request) async {
  int page = _pageFromUrl(request.url);
  var path = request.url.path;
  if (path.endsWith('.json')) {
    return packagesHandlerJson(request, page, true);
  } else if (request.url.queryParameters['format'] == 'json') {
    return packagesHandlerJson(request, page, false);
  } else {
    return packagesHandlerHtml(request, page);
  }
}

/// Handles requests for /packages - JSON
packagesHandlerJson(
    shelf.Request request, int page, bool dotJsonResponse) async {
  final PageSize = 50;

  var offset = PageSize * (page - 1);
  var limit = PageSize + 1;

  var packages = await backend.latestPackages(offset: offset, limit: limit);
  bool lastPage = packages.length < limit;

  var nextPageUrl;
  if (!lastPage) {
    nextPageUrl =
        request.requestedUri.resolve('/packages.json?page=${page + 1}');
  }

  String toUrl(Package package) {
    var postfix = dotJsonResponse ? '.json' : '';
    return request.requestedUri.resolve(
        '/packages/${Uri.encodeComponent(package.name)}$postfix').toString();
  }
  var json = {
    'packages' : packages.take(PageSize).map(toUrl).toList(),
    'next' : nextPageUrl != null ? '$nextPageUrl' : null,

    // NOTE: We're not returning the following entry:
    //   - 'prev'
    //   - 'pages'
  };

  return _jsonResponse(json);
}

/// Handles requests for /packages - HTML
packagesHandlerHtml(shelf.Request request, int page) async {
  var offset = PackageLinks.RESULTS_PER_PAGE * (page - 1);
  var limit = PackageLinks.MAX_PAGES * PackageLinks.RESULTS_PER_PAGE + 1;

  var packages = await backend.latestPackages(offset: offset, limit: limit);
  var links = new PackageLinks(offset, offset + packages.length);
  var pagePackages = packages.take(PackageLinks.RESULTS_PER_PAGE).toList();
  var versions = await backend.lookupLatestVersions(pagePackages);
  return _htmlResponse(
      templateService.renderPkgIndexPage(pagePackages, versions, links));
}


/// Handles requests for /packages/...  - multiplexes to HTML/JSON handlers
///
/// Handles the following URLs:
///   - /packages/<package>
///   - /packages/<package>/versions
packageHandler(shelf.Request request) {
  var path = request.url.path.substring('/packages/'.length);
  if (path.length == 0) {
    return _notFoundHandler(request);
  }

  int slash = path.indexOf('/');
  if (slash == -1) {
    bool responseAsJson = request.url.queryParameters['format'] == 'json';
    if (path.endsWith('.json')) {
      responseAsJson = true;
      path = path.substring(0, path.length - '.json'.length);
    }
    if (responseAsJson) {
      return packageShowHandlerJson(request, Uri.decodeComponent(path));
    } else {
      return packageShowHandlerHtml(request, Uri.decodeComponent(path));
    }
  }

  var package = Uri.decodeComponent(path.substring(0, slash));
  if (path.substring(slash).startsWith('/versions')) {
    path = path.substring(slash + '/versions'.length);
    if (path.startsWith('/') && path.endsWith('.yaml')) {
      path = path.substring(1, path.length - '.yaml'.length);
      String version = Uri.decodeComponent(path);
      return packageVersionHandlerYaml(request, package, version);
    } else {
      return packageVersionsHandler(request, package);
    }
  }
  return _notFoundHandler(request);
}

/// Handles requests for /packages/<package> - JSON
packageShowHandlerJson(shelf.Request request, String packageName) async {
  Package package = await backend.lookupPackage(packageName);
  if (package == null) return _notFoundHandler(request);

  var versions = await backend.versionsOfPackage(packageName);
  _sortVersionsDesc(versions, decreasing: false);

  var json = {
    'name' : package.name,
    'uploaders': package.uploaderEmails,
    'versions':
        versions.map((packageVersion) => packageVersion.version).toList(),
  };
  return _jsonResponse(json);
}

/// Handles requests for /packages/<package> - HTML
packageShowHandlerHtml(shelf.Request request, String packageName) async {
  String cachedPage;
  if (backend.uiPackageCache != null) {
    cachedPage = await backend.uiPackageCache.getUIPackagePage(packageName);
  }

  if (cachedPage == null) {
    Package package = await backend.lookupPackage(packageName);
    if (package == null) return _notFoundHandler(request);

    var versions = await backend.versionsOfPackage(packageName);
    _sortVersionsDesc(versions);

    var latestVersion = versions.where(
        (version) => version.key == package.latestVersionKey).first;

    var first10Versions = versions.take(10).toList();

    var versionDownloadUrls = await Future.wait(
        first10Versions.map((PackageVersion version) {
          return backend.downloadUrl(packageName, version.version);
        }).toList());

    cachedPage = templateService.renderPkgShowPage(
        package, first10Versions, versionDownloadUrls, latestVersion,
        versions.length);
    if (backend.uiPackageCache != null) {
      await backend.uiPackageCache.setUIPackagePage(packageName, cachedPage);
    }
  }

  return _htmlResponse(cachedPage);
}

/// Handles requests for /packages/<package>/versions
packageVersionsHandler(shelf.Request request, String packageName) async {
  var versions = await backend.versionsOfPackage(packageName);
  if (versions.isEmpty) return _notFoundHandler(request);

  _sortVersionsDesc(versions);

  var versionDownloadUrls =  await Future.wait(
      versions.map((PackageVersion version) {
    return backend.downloadUrl(packageName, version.version);
  }).toList());

  return _htmlResponse(templateService.renderPkgVersionsPage(
      packageName, versions, versionDownloadUrls));
}

/// Handles requests for /packages/<package>/versions/<version>.yaml
packageVersionHandlerYaml(request, String package, String version) async {
  var packageVersion = await backend.lookupPackageVersion(package, version);
  if (packageVersion == null) {
    return _notFoundHandler(request);
  } else {
    return _yamlResponse(packageVersion.pubspec.jsonString);
  }
}

/// Handles request for /api/packages?page=<num>
apiPackagesHandler(shelf.Request request) async {
  final int PageSize = 100;

  int page = _pageFromUrl(request.url);

  var packages = await backend.latestPackages(
      offset: PageSize * (page - 1), limit: PageSize + 1);

  // NOTE: We queried for `PageSize+1` packages, if we get less than that, we
  // know it was the last page.
  // But we only use `PageSize` packages to display in the result.
  List<Package> pagePackages = packages.take(PageSize).toList();
  List<PackageVersion> pageVersions =
      await backend.lookupLatestVersions(pagePackages);

  var lastPage = packages.length == pagePackages.length;

  var packagesJson = [];

  var uri = request.requestedUri;
  for (var version in pageVersions) {
    var versionString = Uri.encodeComponent(version.version);
    var packageString = Uri.encodeComponent(version.package);

    var apiArchiveUrl = uri
        .resolve('/packages/$packageString/versions/$versionString.tar.gz')
        .toString();
    var apiPackageUrl =
        uri.resolve('/api/packages/$packageString').toString();
    var apiPackageVersionUrl = uri
        .resolve('/api/packages/$packageString/versions/$versionString')
        .toString();
    var apiNewPackageVersionUrl =
        uri.resolve('/api/packages/$packageString/new').toString();
    var apiUploadersUrl =
        uri.resolve('/api/packages/$packageString/uploaders').toString();
    var versionUrl  = uri
        .resolve('/api/packages/$packageString/versions/{version}')
        .toString();

    packagesJson.add({
      'name' : version.package,
      'latest' : {
          'version' : version.version,
          'pubspec' : version.pubspec.asJson,

          // TODO: We should get rid of these:
          'archive_url' : apiArchiveUrl,
          'package_url' : apiPackageUrl,
          'url' : apiPackageVersionUrl,

          // NOTE: We do not add the following
          //    - 'new_dartdoc_url'
      },
      // TODO: We should get rid of these:
      'url' : apiPackageUrl,
      'version_url' : versionUrl,
      'new_version_url' : apiNewPackageVersionUrl,
      'uploaders_url' : apiUploadersUrl,
    });
  }

  var json = {
    'next_url' : null,
    'packages' : packagesJson,

    // NOTE: We do not add the following:
    //     - 'pages'
    //     - 'prev_url'
  };

  if (!lastPage) {
    json['next_url'] =
        '${request.requestedUri.resolve('/api/packages?page=${page + 1}')}';
  }

  return _jsonResponse(json);
}


shelf.Response _notFoundHandler(request) {
  var status = '404 Not Found';
  var message = 'The path \'${request.url.path}\' was not found.';
  return _htmlResponse(
      templateService.renderErrorPage(status, message, null), status: 404);
}

shelf.Response _htmlResponse(String content, {int status: 200}) {
  return new shelf.Response(
      status,
      body: content,
      headers: {'content-type' : 'text/html; charset="utf-8"'});
}

shelf.Response _jsonResponse(Map json, {int status: 200}) {
  return new shelf.Response(
      status,
      body: JSON.encode(json),
      headers: {'content-type' : 'application/json; charset="utf-8"'});
}

shelf.Response _yamlResponse(String yamlString, {int status: 200}) {
  return new shelf.Response(
      status,
      body: yamlString,
      headers: {'content-type' : 'text/yaml; charset="utf-8"'});
}

shelf.Response _atomXmlResponse(String content, {int status: 200}) {
  return new shelf.Response(
      status,
      body: content,
      headers: {'content-type' : 'application/atom+xml; charset="utf-8"'});
}

shelf.Response _redirectResponse(url) {
  return new shelf.Response.seeOther(url);
}


/// Sorts [versions] according to the semantic versioning specification.
void _sortVersionsDesc(List<PackageVersion> versions, {bool decreasing: true}) {
  versions.sort((PackageVersion a, PackageVersion b) {
    if (decreasing) {
      return semver.Version.prioritize(b.semanticVersion, a.semanticVersion);
    } else {
      return semver.Version.prioritize(a.semanticVersion, b.semanticVersion);
    }
  });
}


/// Extracts the 'page' query parameter from [url].
///
/// Returns a valid positive integer. If [maxPages] is given, the result is
/// clamped to [maxPages].
int _pageFromUrl(Uri url, {int maxPages}) {
  var pageAsString = url.queryParameters['page'];
  int pageAsInt = 1;
  if (pageAsString != null) {
    try {
      pageAsInt = max(int.parse(pageAsString), 1);
    } catch (_, __) { }
  }

  if (maxPages != null && pageAsInt > maxPages) pageAsInt = maxPages;
  return pageAsInt;
}
