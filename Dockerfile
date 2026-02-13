FROM nginx:alpine

# Remove default site
RUN rm /etc/nginx/conf.d/default.conf

# Custom nginx config for static serving
COPY nginx.conf /etc/nginx/conf.d/palflow.conf

# Copy static files
COPY index.html /usr/share/nginx/html/
COPY assets/    /usr/share/nginx/html/assets/

EXPOSE 80
