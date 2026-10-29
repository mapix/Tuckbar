ARG BASE=harbor.novarock.dev:8080/mirrors/nginx:1.25-alpine
FROM ${BASE}
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY landing/ /usr/share/nginx/html/
RUN chmod -R a+rX /usr/share/nginx/html /etc/nginx/conf.d
