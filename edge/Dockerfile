FROM nginx:alpine

RUN apk add --no-cache openssl

RUN rm -f /etc/nginx/conf.d/default.conf

COPY nginx.template.conf /etc/nginx/nginx.template.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
