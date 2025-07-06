# Dockerfile для сборки OpenWrt 24.10.x (Ath79, Archer C6 v2) из официального git.openwrt.org

FROM ubuntu:20.04

# 1. Неинтерактивный режим для apt
ENV DEBIAN_FRONTEND=noninteractive

# 2. Устанавливаем зависимости
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git build-essential libncurses5-dev gawk gettext \
      libssl-dev xsltproc unzip python3-distutils gcc-multilib \
      rsync zstd curl wget file ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 3. Задаём рабочую папку
WORKDIR /openwrt-src

# 4. Клонируем OpenWrt из git.openwrt.org сразу ветку openwrt-24.10
RUN git clone --depth 1 --branch openwrt-24.10 \
      https://git.openwrt.org/openwrt/openwrt.git . && \
    ./scripts/feeds update -a && \
    ./scripts/feeds install -a

# 5. Объявляем volume для готовых образов
VOLUME ["/openwrt-src/"]

# 6. По умолчанию запускаем shell
CMD [ "bash" ]
