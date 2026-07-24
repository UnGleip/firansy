# =============================================================================
# پارامترهای ورودی با قابلیت انتخاب رجیستری (پیش‌فرض: devneeds)
# در صورت نیاز به رجیستری پشتیبان، مقدار BASE_REGISTRY را به docker-mirror.liara.ir تغییر دهید
# =============================================================================
ARG BASE_REGISTRY="docker.devneeds.ir"
ARG DEBIAN_MIRROR="linux-mirror.liara.ir/repository/debian"   # آینه Debian از لیارا
ARG RUBYGEMS_MIRROR="https://rubygems.org"                    # در صورت نیاز به آینه داخلی، میتوانید از mirror.liara.ir استفاده کنید
ARG NPM_MIRROR="https://mirror.liara.ir/repository/npm/"      # آینه npm از لیارا

ARG TARGETPLATFORM=${TARGETPLATFORM}
ARG BUILDPLATFORM=${BUILDPLATFORM}

ARG RUBY_VERSION="3.2.2"
ARG NODE_MAJOR_VERSION="20"
ARG DEBIAN_VERSION="bullseye"

# =============================================================================
# تصاویر پایه از رجیستری مشخص شده
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
# مرحله ۱: پایه (تنظیم مخازن Debian با آینه انتخابی)
# =============================================================================
FROM ruby AS base

ARG DEBIAN_MIRROR
ARG DEBIAN_VERSION

RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN echo "deb http://${DEBIAN_MIRROR}/ ${DEBIAN_VERSION} main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://${DEBIAN_MIRROR}/ ${DEBIAN_VERSION}-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://${DEBIAN_MIRROR}/ ${DEBIAN_VERSION}-security main contrib non-free" >> /etc/apt/sources.list

RUN apt-get update -qq && \
    apt-get dist-upgrade -yq && \
    apt-get install -y --no-install-recommends \
        curl file git libjemalloc2 procps tini tzdata wget \
        libexpat1 libglib2.0-0 libicu67 libidn11 libpq5 \
        libreadline8 libssl1.1 libyaml-0-2 libvips42 ffmpeg \
        imagemagick postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

RUN patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby || true

RUN groupadd -g "${GID}" mastodon && \
    useradd -l -u "${UID}" -g "${GID}" -m -d /opt/mastodon mastodon && \
    ln -s /opt/mastodon /mastodon

WORKDIR /opt/mastodon

# =============================================================================
# مرحله ۲: وابستگی‌های Ruby (Gems) با آینه قابل تنظیم
# =============================================================================
FROM base AS ruby-deps

ARG RUBYGEMS_MIRROR
COPY Gemfile Gemfile.lock ./

RUN bundle config mirror.https://rubygems.org ${RUBYGEMS_MIRROR} && \
    bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle config set silence_root_warning 'true' && \
    bundle install -j"$(nproc)"

# =============================================================================
# مرحله ۳: وابستگی‌های Node.js (با Corepack و Yarn 4)
# =============================================================================
FROM node AS node-deps

ARG NPM_MIRROR
WORKDIR /opt/mastodon
COPY package.json yarn.lock ./

# فعال‌سازی corepack، نصب Yarn 4 و تنظیم رجیستری npm به آینه لیارا
RUN corepack enable && \
    corepack prepare yarn@4.17.1 --activate && \
    yarn config set npmRegistryServer ${NPM_MIRROR} && \
    yarn install --immutable --non-interactive --production

# =============================================================================
# مرحله ۴: پیش‌کامپایل Assets (CSS, JS, etc.)
# =============================================================================
FROM base AS assets

COPY . /opt/mastodon/
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle
COPY --from=node-deps /opt/mastodon/node_modules /opt/mastodon/node_modules

ENV SECRET_KEY_BASE=precompile_placeholder OTP_SECRET=precompile_placeholder
RUN bundle exec rails assets:precompile && rm -fr /opt/mastodon/tmp

# =============================================================================
# مرحله ۵: تصویر نهایی برای اجرا (Production)
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

# پورت ۳۱۰۰ برای وب سرویس (جلوگیری از تداخل با سایر سرویس‌های Dokploy)
EXPOSE 3100

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
