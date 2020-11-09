FROM openresty/openresty:alpine-fat
LABEL maintainer="Xiao Yu <hi@xyu.io>"

WORKDIR /app

COPY . /git-repo

# link devel files
RUN echo 'linking files...' \
  && mkdir -p /app/conf/ /app/logs/ /app/html/ \
  && ln -s /git-repo/devel/.opmrc /root/ \
  && ln -s /git-repo/lib /app/ \
  && ln -s /dev/stdout /app/logs/access.log \
  && ln -s /dev/stderr /app/logs/error.log \
  && echo 'done!'

RUN echo 'building mog proxy...' \
  && opm get ledgetech/lua-resty-http \
  && cd /git-repo/ \
  && opm build
