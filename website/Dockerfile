FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html
COPY app.js /usr/share/nginx/html/app.js
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Ensure nginx's worker process (non-root) can actually read these files —
# without this, COPY can preserve restrictive host permissions and cause
# a 403 Forbidden at runtime.
RUN chmod 644 /usr/share/nginx/html/index.html /usr/share/nginx/html/app.js
