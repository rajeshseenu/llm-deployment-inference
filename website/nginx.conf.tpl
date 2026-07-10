server {
  listen 80;

  location / {
    root /usr/share/nginx/html;
    index index.html;
  }

  # Proxies browser requests to vLLM's internal Service — browser only ever
  # talks to this pod, never directly to vllm-service. Namespace is
  # substituted at build time by install.sh (envsubst).
  location /v1/ {
    proxy_pass http://vllm-service.${K8S_NAMESPACE}.svc.cluster.local:8000/v1/;
    proxy_set_header Host $host;
  }
}
