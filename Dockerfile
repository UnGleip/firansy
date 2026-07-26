# =============================================================================
# پارامترهای ورودی با پشتیبانی از آینه‌های داخلی (فقط برای Docker Registry)
# =============================================================================
ARG BASE_REGISTRY="docker.devneeds.ir"

ARG TARGETPLATFORM=${TARGETPLATFORM}
ARG BUILDPLATFORM=${BUILDPLATFORM}

ARG RUBY_VERSION="3.3.0"
ARG NODE_MAJOR_VERSION="20"
ARG DEBIAN_VERSION="bookworm"

# =============================================================================
# تصاویر پایه (از رجیستری داخلی داکر)
# =============================================================================
FROM ${BASE_REGISTRY}/node:${NODE_MAJOR_VERSION}-${DEBIAN_VERSION}-slim AS node
FROM ${BASE_REGISTRY}/ruby:${RUBY_VERSION}-slim-${DEBIAN_VERSION} AS ruby

# =============================================================================
# متغیرهای ساخت
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
# مرحله ۱: پایه
# =============================================================================
FROM ruby AS base

ARG DEBIAN_VERSION

RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN echo "deb http://deb.debian.org/debian/ ${DEBIAN_VERSION} main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian/ ${DEBIAN_VERSION}-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian-security/ ${DEBIAN_VERSION}-security main contrib non-free" >> /etc/apt/sources.list

RUN apt update -qq && \
    apt dist-upgrade -yq && \
    apt install -y --no-install-recommends \
        curl file git libjemalloc2 procps tini tzdata wget \
        libexpat1 libglib2.0-0 libicu72 libidn12 libpq5 \
        libreadline8 libssl3 libyaml-0-2 libvips42 ffmpeg \
        imagemagick postgresql-client redis-tools \
        build-essential python3 patchelf libidn-dev libicu-dev \
    && rm -rf /var/lib/apt/lists/*

RUN patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby

RUN groupadd -g "${GID}" mastodon && \
    useradd -l -u "${UID}" -g "${GID}" -m -d /opt/mastodon mastodon && \
    ln -s /opt/mastodon /mastodon

WORKDIR /opt/mastodon

# =============================================================================
# مرحله ۲: وابستگی‌های Ruby (نصب کاملاً آفلاین از vendor/cache)
# =============================================================================
FROM base AS ruby-deps

COPY Gemfile Gemfile.lock ./
# کپی کردن Gemهای کش شده
COPY vendor/cache ./vendor/cache

RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle config set silence_root_warning 'true' && \
    # استفاده از سوئئیچ local-- برای عدم اتصال به اینترنت
    bundle install --local -j"$(nproc)"

# =============================================================================
# مرحله ۳: وابستگی‌های Node.js با Yarn 4 (نصب آفلاین)
# =============================================================================
FROM node AS node-deps

WORKDIR /opt/mastodon

# کپی تمامی فایل‌های کانفیگ و کش Yarn
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn ./.yarn

RUN corepack enable && \
    corepack prepare yarn@4.17.1 --activate && \
    # نصب پکیج‌ها به صورت آفلاین و بدون دانلود مجدد
    yarn install --immutable --mode=skip-build && \
    yarn workspaces focus --production

# =============================================================================
# مرحله ۴: پیش‌کامپایل Assets
# =============================================================================
FROM base AS assets

COPY . /opt/mastodon/
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle
COPY --from=node-deps /opt/mastodon/node_modules /opt/mastodon/node_modules

ENV SECRET_KEY_BASE=precompile_placeholder OTP_SECRET=precompile_placeholder
RUN bundle exec rails assets:precompile && rm -fr /opt/mastodon/tmp

# =============================================================================
# مرحله ۵: تصویر نهایی
# =============================================================================
FROM base AS production

COPY . /opt/mastodon/
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle
COPY --from=node-deps /opt/mastodon/node_modules /opt/mastodon/node_modules
COPY --from=assets /opt/mastodon/public/packs /opt/mastodon/public/packs
COPY --from=assets /opt/mastodon/public/assets /opt/mastodon/public/assets

RUN mkdir -p /opt/mastodon/public/system && \
    chown -R mastodon:mastodon /opt/mastodon/tmp /opt/mastodon/public/system

USER mastodon

EXPOSE 3100

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
