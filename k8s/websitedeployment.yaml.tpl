apiVersion: apps/v1
kind: Deployment
metadata:
  name: chat-website
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chat-website
  template:
    metadata:
      labels:
        app: chat-website
    spec:
      imagePullSecrets:
        - name: ${ACR_SECRET_NAME}
      containers:
        - name: website
          image: "${WEBSITE_IMAGE}"
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: chat-website-service
  namespace: ${K8S_NAMESPACE}
spec:
  selector:
    app: chat-website
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
