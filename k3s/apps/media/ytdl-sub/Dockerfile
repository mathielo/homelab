# Derived ytdl-sub image adding the Intel VA-API driver for hardware H.264
# encoding on k3s-node-02's iGPU. The default (Alpine) ytdl-sub image already
# ships a VAAPI-capable ffmpeg from Alpine's repos, so we only add the matching
# distro driver + libva — no version skew between ffmpeg and the driver.
# (intel-media-driver is the bulk of the added size; the base stays Alpine-light.)
#
# Build + push (tag must match the base ytdl-sub version so values.yaml lines up):
#   docker build -t ghcr.io/mathielo/ytdl-sub-vaapi:2026.06.12 k3s/apps/media/ytdl-sub
#   docker push ghcr.io/mathielo/ytdl-sub-vaapi:2026.06.12
FROM ghcr.io/jmbannon/ytdl-sub:2026.06.23

USER root
RUN apk add --no-cache \
      --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community \
      intel-media-driver \
      libva \
      libva-utils

ENV LIBVA_DRIVER_NAME=iHD
