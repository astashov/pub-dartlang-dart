FROM google/dart-runtime-base:1.15.0

WORKDIR /project/app

ADD app.yaml /project/
ADD app/pubspec.* /project/app/

ADD key.json /project/key.json

RUN pub get

ADD app /project/app

RUN pub get --offline
