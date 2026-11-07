FROM php:8.3-apache

ARG SSP_VERSION=2.4.1
ARG SSP_SHA256=f78d1521f6abfbe9219fdcf6193355518d5b90d7369cfa183663519b431f5a60

RUN curl -fsSL -o /tmp/ssp.tgz \
        "https://github.com/simplesamlphp/simplesamlphp/releases/download/v${SSP_VERSION}/simplesamlphp-${SSP_VERSION}-slim.tar.gz" \
    && echo "${SSP_SHA256}  /tmp/ssp.tgz" | sha256sum -c - \
    && mkdir -p /var/simplesamlphp \
    && tar -xzf /tmp/ssp.tgz --strip-components=1 -C /var/simplesamlphp \
    && rm /tmp/ssp.tgz \
    && mkdir -p /var/cache/simplesamlphp \
    && chown www-data:www-data /var/cache/simplesamlphp

COPY apache-site.conf /etc/apache2/sites-available/000-default.conf
