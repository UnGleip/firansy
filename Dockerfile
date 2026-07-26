# syntax=docker/dockerfile:1

# ------------------------------------------------------------------------------
# 1. Base Image - Ruby Setup
# ------------------------------------------------------------------------------
FROM docker.devneeds.ir/ruby:3.3.0-slim-bookworm AS base

WORKDIR /opt/mastodon

# تنظیم سورس‌های مخازن و نصب نیازمندی‌های سیستم
RUN echo "deb http://deb.debian.org/debian/ bookworm main contrib non-free" > /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb http://deb.debian.org/debian-security/ bookworm-security main contrib non-free" >> /etc/apt/sources.list

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

RUN groupadd -g "991" mastodon && \
    useradd -l -u "991" -g "991" -m -d /opt/mastodon mastodon && \
    ln -s /opt/mastodon /mastodon

# ------------------------------------------------------------------------------
# 2. Node.js & Yarn Dependencies Setup
# ------------------------------------------------------------------------------
FROM docker.devneeds.ir/node:20-bookworm-slim AS node-deps

WORKDIR /opt/mastodon

# کپی فایل‌های کانفیگ Yarn
COPY package.json yarn.lock .yarnrc.yml ./

# ساخت پوشه .yarn در صورت عدم وجود
RUN mkdir -p .yarn
COPY .yarn* ./.yarn/

# حذف --immutable برای جلوگیری از ارور عدم تطابق yarn.lock
RUN corepack enable && yarn install --no-immutable

# ------------------------------------------------------------------------------
# 3. Ruby Gems Setup
# ------------------------------------------------------------------------------
FROM base AS ruby-deps

WORKDIR /opt/mastodon

COPY Gemfile Gemfile.lock ./

# ساخت پوشه vendor/cache در صورت عدم وجود
RUN mkdir -p vendor/cache
COPY vendor/cach[e] ./vendor/cache/

RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle install -j$(nproc)

# ------------------------------------------------------------------------------
# 4. Final Build Stage
# ------------------------------------------------------------------------------
FROM base AS final

WORKDIR /opt/mastodon

COPY --chown=mastodon:mastodon . .
COPY --from=node-deps /opt/mastodon/node_modules ./node_modules
COPY --from=ruby-deps /usr/local/bundle /usr/local/bundle

ENV RAILS_ENV="production" \
    NODE_ENV="production" \
    PORT=3100 \
    STREAMING_API_BASE_URL="http://localhost:4000"

USER mastodon

# اکسپوز پورت‌های وب (3100) و استریمینگ (4000)
EXPOSE 3100 4000

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
