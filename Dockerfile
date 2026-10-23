# Thin CTS wrapper around the official QIIME 2 amplicon distribution.
# Pin to a real release tag (see https://quay.io/repository/qiime2/amplicon?tab=tags);
# record the digest in the CTS registration so the image can't drift.
ARG QIIME_VERSION=2026.1
FROM quay.io/qiime2/amplicon:${QIIME_VERSION}

# Bake the plugin cache into the image so runs don't need to write it.
RUN qiime dev refresh-cache

COPY entrypoint.sh /opt/cts/entrypoint.sh
RUN chmod 755 /opt/cts/entrypoint.sh

# CTS requires a non-root image.
RUN useradd --create-home --uid 1000 cts
USER cts

ENTRYPOINT ["/opt/cts/entrypoint.sh"]
