#! /bin/sh

nginx-build -d work -openresty -openrestyversion 1.11.2.5 -pcre -openssl -zlib  \
--conf-path=/etc/nginx/nginx.conf \
--http-log-path=/var/log/nginx/access.log \
--error-log-path=/var/log/nginx/error.log \
--lock-path=/var/lock/nginx.lock \
--pid-path=/run/nginx.pid \
--with-debug \
--with-pcre-jit \
--with-ipv6 \
--with-http_ssl_module \
--with-http_stub_status_module \
--with-http_realip_module \
--with-http_auth_request_module \
--with-http_addition_module \
--with-http_dav_module \
--with-http_gunzip_module \
--with-http_gzip_static_module \
--with-http_image_filter_module \
--with-http_v2_module \
--with-http_sub_module \
--with-http_xslt_module \
--with-stream \
--with-stream_ssl_module \
--with-mail \
--with-mail_ssl_module \
--with-threads

cd work/openresty/1.11.2.5/openresty-1.11.2.5
sudo make install
rm -rf work

