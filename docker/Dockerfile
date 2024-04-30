FROM redhat/ubi9-minimal

LABEL org.opencontainers.image.authors="info@percona.com"

RUN microdnf -y update; \
    microdnf -y install glibc-langpack-en

ENV VALKEY_VERSION 7.2.5
ENV OS_VER el9
ENV FULL_VALKEY_VERSION "$VALKEY_VERSION.$OS_VER"

# check repository package signature in secure way
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 430BDF5C56E7C94E848EE60C1C4CBDCDCD2EFD2A 99DB70FAE1D7CE227FB6488205B555B38483C65D; \
    gpg --batch --export --armor 430BDF5C56E7C94E848EE60C1C4CBDCDCD2EFD2A > ${GNUPGHOME}/RPM-GPG-KEY-Percona; \
    gpg --batch --export --armor 99DB70FAE1D7CE227FB6488205B555B38483C65D > ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    rpmkeys --import ${GNUPGHOME}/RPM-GPG-KEY-Percona ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    microdnf install -y findutils; \
    curl -Lf -o /tmp/percona-release.rpm https://repo.percona.com/yum/percona-release-latest.noarch.rpm; \
    rpmkeys --checksig /tmp/percona-release.rpm; \
    rpm -i /tmp/percona-release.rpm; \
    rm -rf "$GNUPGHOME" /tmp/percona-release.rpm; \
    rpm --import /etc/pki/rpm-gpg/PERCONA-PACKAGING-KEY; \
    percona-release disable all; \
    percona-release enable valkey experimental

RUN set -ex; \
    microdnf -y install \
        tar \
        procps-ng \
        shadow-utils

# create mysql user/group before mysql installation
RUN groupadd -g 1010 valkey; \
    useradd -u 1010 -r -g 1010 -s /sbin/nologin \
        -c "Default Application User" valkey

RUN set -ex; \
    microdnf -y install \
        valkey-${VALKEY_VERSION}; \
    \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

RUN mkdir /data && chown valkey:valkey /data
VOLUME /data
WORKDIR /data

COPY docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

USER valkey

EXPOSE 6379
CMD ["valkey-server"]
