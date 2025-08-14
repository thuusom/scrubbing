FROM nginx:alpine
ARG CONTENT_BASE
ENV CONTENT_BASE=${CONTENT_BASE:-http://localhost:8080}

# Ind med player UI
COPY index.html /usr/share/nginx/html/index.html
COPY nginx.conf /etc/nginx/conf.d/default.conf