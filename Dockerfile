FROM openresty/openresty:alpine-fat
LABEL maintainer="Xiao Yu <hi@xyu.io>"

WORKDIR /app

COPY devel/.opmrc /root/.opmrc
COPY lib/ /app/lib/
COPY \
  dist.ini \
  README.md \
  /app/

RUN opm build
