apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-server
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 1
  strategy:
    type: Recreate
    # Recreate (not RollingUpdate): this deployment's resource requests are
    # sized close to node capacity, so running two replicas briefly during
    # a rolling update can fail to schedule (Insufficient cpu/memory).
  selector:
    matchLabels:
      app: vllm-server
  template:
    metadata:
      labels:
        app: vllm-server
    spec:
      imagePullSecrets:
        - name: ${ACR_SECRET_NAME}
      containers:
        - name: vllm
          image: "${VLLM_IMAGE}"
          ports:
            - containerPort: 8000
          env:
            - name: VLLM_CPU_KVCACHE_SPACE
              value: "${VLLM_KVCACHE_GB}"
            - name: TORCHDYNAMO_DISABLE
              value: "1"
              # Disables torch.compile/Dynamo globally. Required on this
              # image's PyTorch install, which is missing
              # torch/csrc/inductor/cpp_prefix.h — any Inductor/dynamo
              # compile attempt (main graph OR the sampler's compiled
              # kernel) fails without this.
          resources:
            requests:
              cpu: "${VLLM_CPU_REQUEST}"
              memory: "${VLLM_MEM_REQUEST}"
            limits:
              cpu: "${VLLM_CPU_LIMIT}"
              memory: "${VLLM_MEM_LIMIT}"
          startupProbe:
            httpGet:
              path: /health
              port: 8000
            failureThreshold: 60
            periodSeconds: 10
            # 60 x 10s = 600s (10 min) budget. CPU model load + warmup has
            # been observed taking several minutes on modest hardware —
            # don't reduce this without confirming your actual startup time.
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
  namespace: ${K8S_NAMESPACE}
spec:
  selector:
    app: vllm-server
  ports:
    - port: 8000
      targetPort: 8000
  type: ClusterIP
