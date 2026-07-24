# syntax=docker/dockerfile:1.18

# =============================================================================
# تنظیمات پایه با قابلیت تغییر رجیستری (برای دور زدن تحریم)
# =============================================================================
ARG BASE_REGISTRY="docker.io"
ARG TARGETPLATFORM=${TARGETPLATFORM}
ARG BUILDPLATFORM=${BUILDPLATFORM}

ARG RUBY_VERSION="3.2.2"
ARG NODE_MAJOR_VERSION="20"
ARG DEBIAN_VERSION="bullseye"   # استفاده از Debian 11 (پایدار)

# تصاویر پایه از رجیستری قابل تنظیم
FROM ${BASE_REGISTRY}/node:${NODE_MAJOR_VERSION}-${DEBIAN_VERSION}-slim AS node
FROM ${BASE_REGISTRY}/ruby:${RUBY_VERSION}-slim-${DEBIAN_VERSION} AS ruby

# =============================================================================
# متغیرهای ساخت (قابل تنظیم با --build-arg)
# =============================================================================
ARG MASTODON_VERSION_PRERELEASE=""
ARG MASTODON_VERSION_METADATA=""
ARG SOURCE_COMMIT=""
ARG RAILS_SERVE_STATIC_FILES="true"
ARG RUBY_YJIT_ENABLE="1"
ARG TZ="Asia/Tehran"
ARG UID="991"
ARG GID="991"

ENV \
  MASTODON_VERSION_PRERELEASE="${MASTODON_VERSION_PRERELEASE}" \
  MASTODON_VERSION_METADATA="${MASTODON_VERSION_METADATA}" \
  SOURCE_COMMIT="${SOURCE_COMMIT}" \
  RAILS_SERVE_STATIC_FILES="${RAILS_SERVE_STATIC_FILES}" \
  RUBY_YJIT_ENABLE="${RUBY_YJIT_ENABLE}" \
  TZ="${TZ}"

ENV \
  BIND="0.0.0.0" \
  NODE_ENV="production" \
  RAILS_ENV="production" \
  DEBIAN_FRONTEND="noninteractive" \
  PATH="${PATH}:/opt/ruby/bin:/opt/mastodon/bin" \
  MALLOC_CONF="narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0"

SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-c"]

# =============================================================================
# مرحله ۱: تنظیم مخازن Apt به میرور ArvanCloud
# =============================================================================
FROM ruby AS base

ARG TARGETPLATFORM
ARG DEBIAN_VERSION

# حذف فایل‌های پاک‌کننده کش
RUN rm -f /etc/apt/apt.conf.d/docker-clean

# تنظیم مخازن Debian برای استفاده از آینه ArvanCloud
RUN echo "deb http://mirror.arvancloud.com/debian/ ${DEBIAN_VERSION} main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://mirror.arvancloud.com/debian/ ${DEBIAN_VERSION}-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://mirror.arvancloud.com/debian-security/ ${DEBIAN_VERSION}-security main contrib non-free" >> /etc/apt/sources.list

# نصب وابستگی‌های اصلی سیستم
RUN apt-get update -qq && \
    apt-get dist-upgrade -yq && \
    apt-get install -y --no-install-recommends \
        curl \
        file \
        git \
        libjemalloc2 \
        procps \
        tini \
        tzdata \
        wget \
        # وابستگی‌های Ruby و Mastodon
        libexpat1 \
        libglib2.0-0 \
        libicu67 \
        libidn11 \
        libpq5 \
        libreadline8 \
        libssl1.1 \
        libyaml-0-2 \
        # libvips (از مخازن Debian)
        libvips42 \
        # ffmpeg (از مخازن Debian)
        ffmpeg \
        # ابزارهای کمکی
        imagemagick \
        postgresql-client \
        redis-tools \
    && rm -rf /var/lib/apt/lists/*

# پچ کردن Ruby برای استفاده از jemalloc
RUN patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby || true

# ایجاد کاربر mastodon
RUN groupadd -g "${GID}" mastodon && \
    useradd -l -u "${UID}" -g "${GID}" -m -d /opt/mastodon mastodon && \
    ln -s /opt/mastodon /mastodon

WORKDIR /opt/mastodon

# =============================================================================
# مرحله ۲: نصب وابستگی‌های Ruby (Bundler) با میرور ArvanCloud
# =============================================================================
FROM base AS ruby-deps

COPY Gemfile Gemfile.lock ./

# تنظیم bundler برای استفاده از آینه ArvanCloud
RUN bundle config mirror.https://rubygems.org https://mirror.arvancloud.com/rubygems && \
    bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle config set silence_root_warning 'true' && \
    bundle install -j"$(nproc)"

# =============================================================================
# مرحله ۳: نصب وابستگی‌های Node.js (Yarn) با میرور ArvanCloud
# =============================================================================
FROM node AS node-deps

WORKDIR /opt/mastodon

COPY package.json yarn.lock ./

# تنظیم yarn برای استفاده از آینه ArvanCloud
RUN yarn config set registry https://mirror.arvancloud.com/npm/ && \
    yarn install --pure-lockfile --non-interactive --production

# =============================================================================
# مرحله ۴: پیش‌کامپایل دارایی‌ها (Assets)
# =============================================================================
FROM base AS assets

# کپی کل کد پروژه
COPY . /opt/mastodon/

# کپی وابستگی‌های نصب‌شده از مراحل قبل
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle
COPY --from=node-deps /opt/mastodon/node_modules /opt/mastodon/node_modules

# متغیرهای موقت برای کامپایل
ENV SECRET_KEY_BASE=precompile_placeholder \
    OTP_SECRET=precompile_placeholder

# پیش‌کامپایل فایل‌های استاتیک
RUN bundle exec rails assets:precompile && \
    rm -fr /opt/mastodon/tmp

# =============================================================================
# مرحله ۵: تصویر نهایی (Production)
# =============================================================================
FROM base AS production

# کپی کل کد (بدون پوشه‌های غیرضروری)
COPY . /opt/mastodon/

# کپی وابستگی‌ها و دارایی‌های کامپایل‌شده
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle
COPY --from=node-deps /opt/mastodon/node_modules /opt/mastodon/node_modules
COPY --from=assets /opt/mastodon/public/packs /opt/mastodon/public/packs
COPY --from=assets /opt/mastodon/public/assets /opt/mastodon/public/assets

# تنظیم مالکیت پوشه‌های موقت
RUN mkdir -p /opt/mastodon/public/system && \
    chown -R mastodon:mastodon /opt/mastodon/tmp /opt/mastodon/public/system

# کاربر نهایی
USER mastodon

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
