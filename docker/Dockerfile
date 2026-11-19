# Base: Red Hat Universal Base Image 9 (minimal). Pinned by digest for
# reproducible builds and to satisfy Docker Scout's "outdated base images"
# policy. The tag is kept for readability; the digest is what pins the build.
# Refresh after a base bump with:
#   docker pull redhat/ubi9-minimal:<tag>
#   docker inspect --format '{{index .RepoDigests 0}}' redhat/ubi9-minimal:<tag>
ARG BASE_IMAGE=redhat/ubi9-minimal
ARG BASE_TAG=latest
ARG BASE_DIGEST=sha256:850143255ee0d1915f09aaa09f6ed31f24086ba605c323badfbefa95b8c52b0e

FROM ${BASE_IMAGE}:${BASE_TAG}@${BASE_DIGEST}

LABEL org.opencontainers.image.authors="info@percona.com" \
      org.opencontainers.image.source="https://github.com/valkey-io/valkey" \
      org.opencontainers.image.vendor="Percona" \
      org.opencontainers.image.title="Percona Valkey" \
      org.opencontainers.image.description="Percona Valkey image built from Percona RPM package" \
      org.opencontainers.image.version="9.2.0" \
      org.opencontainers.image.base.name="redhat/ubi9-minimal:latest" \
      org.opencontainers.image.base.digest="sha256:850143255ee0d1915f09aaa09f6ed31f24086ba605c323badfbefa95b8c52b0e"

RUN microdnf -y update && \
    microdnf -y install glibc-langpack-en

ENV VALKEY_VERSION=9.2.0

ARG REPO_CHANNEL=testing

# check repository package signature in secure way
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys 4D1BB29D63D98E422B2113B19334A25F8507EFA5 99DB70FAE1D7CE227FB6488205B555B38483C65D; \
    gpg --batch --export --armor 4D1BB29D63D98E422B2113B19334A25F8507EFA5 > ${GNUPGHOME}/PERCONA-PACKAGING-KEY; \
    gpg --batch --export --armor 99DB70FAE1D7CE227FB6488205B555B38483C65D > ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    rpmkeys --import ${GNUPGHOME}/PERCONA-PACKAGING-KEY ${GNUPGHOME}/RPM-GPG-KEY-centosofficial; \
    microdnf install -y findutils; \
    curl -Lf -o /tmp/percona-release.rpm https://repo.percona.com/yum/percona-release-latest.noarch.rpm; \
    rpmkeys --checksig /tmp/percona-release.rpm; \
    rpm -i /tmp/percona-release.rpm; \
    rm -rf "$GNUPGHOME" /tmp/percona-release.rpm; \
    rpm --import /etc/pki/rpm-gpg/PERCONA-PACKAGING-KEY; \
    percona-release disable all; \
    percona-release enable valkey-92 ${REPO_CHANNEL}; \
    microdnf -y install \
        tar \
        gawk \
        procps-ng \
        shadow-utils \
        percona-valkey; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum

# Generate a real SBOM (SPDX + CycloneDX) of the installed image, then remove
# the generator so it is not shipped. Syft scans the RPM database for an
# accurate inventory of every installed package; /tmp is excluded so neither
# the syft binary nor its own output appear in the catalog.
RUN set -ex; \
    mkdir -p /tmp/sbom-bin; \
    curl -sSfL https://get.anchore.io/syft | sh -s -- -b /tmp/sbom-bin; \
    vkver="$(valkey-server --version | awk '{print $3}' | cut -d= -f2)"; \
    /tmp/sbom-bin/syft scan dir:/ \
        --source-name percona-valkey --source-version "$vkver" \
        --exclude './tmp' --exclude './proc' --exclude './sys' --exclude './dev' \
        -o spdx-json=/usr/local/valkey.spdx.json \
        -o cyclonedx-json=/usr/local/valkey.cdx.json; \
    rm -rf /tmp/sbom-bin

RUN mkdir /data && chown valkey:valkey /data
VOLUME /data
WORKDIR /data

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

USER valkey

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD valkey-cli ping || exit 1

EXPOSE 6379
CMD ["valkey-server"]
