### 前言

 **上一次对kubernetes配置了 traefik ，如果需要traefik代理https的应用，就需要配置https,下面就针对traefik 的https做配置**

### 准备工作：
下面的操作在deploy节点操作，此节点同时又被定义为了我的master节点。
- 证书：自己生成，或使用机构颁发的证书,
私签证书命令，需要有安装OpenSSL：
```
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -subj "/CN=泛域名，如*.abc.com"
```

我这里使用了LetsEncrypt的证书，我的tls.crt tls.key存放在了`/etc/kubernetes/ssl/`,注意名字是tls,不然会报错，“找不到tls.crt证书文件”
```
cd /etc/kubernetes/ssl/
kubectl create secret generic traefik-cert --from-file=tls.crt --from-file=tls.key -n kube-system
```
检查一下：
```
[root@master conf]# kubectl get secrets -n kube-system | grep traefik
traefik-cert                             Opaque                                2         42m
traefik-ingress-controller-token-78tll   kubernetes.io/service-account-token   3         1h
```
- traefik.toml
```
cd /etc/k8s/conf
# vim traefik.toml 
defaultEntryPoints = ["http","https"]
[entryPoints]
  [entryPoints.http]
  address = ":80"
    [entryPoints.http.redirect]
    entryPoint = "https"
  [entryPoints.https]
  address = ":443"
    [entryPoints.https.tls]
      [[entryPoints.https.tls.certificates]]
      certFile = "/ssl/tls.crt"
      keyFile = "/ssl/tls.key"
```
- configmap：
```
kubectl create configmap traefik-conf --from-file=traefik.toml -n kube-system
```
检查一下：

    [root@master conf]# kubectl get cm -n kube-system | grep traefik
    traefik-conf                         1         38m
当然也可以查看详细的描述信息,命令后输出的内容比较丰富，这里省略输出：
```
[root@master conf]# kubectl describe cm traefik-conf -n kube-system
```
把上述的文件放到node上面对应的目录,可以使用下面的脚本快速同步一下
```
#!/bin/bash

for i in `seq 11 15`
do
  rsync -av /etc/kubernetes/ssl/tls* 192.168.2.$i:/etc/kubernetes/ssl/
  rsync -av /etc/k8s/ 192.168.2.$i:/etc/k8s/
done
```
### 关键配置文件

```
[root@master conf]# tree ./
./
├── traefik-depoyment.yaml
├── traefik-rbac.yaml
├── traefik.toml
└── ui.yaml
```
- traefik-rbac.yaml
```
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups:
      - ""
    resources:
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
- kind: ServiceAccount
  name: traefik-ingress-controller
  namespace: kube-system
```
应用配置：

    kubectl apply -f traefik-rbac.yaml
- traefik-depoyment.yaml
```
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
---
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
  labels:
    k8s-app: traefik-ingress-lb
spec:
  selector:
    matchLabels:
      k8s-app: traefik-ingress-lb
  template:
    metadata:
      labels:
        k8s-app: traefik-ingress-lb
        name: traefik-ingress-lb
    spec:
      serviceAccountName: traefik-ingress-controller
      terminationGracePeriodSeconds: 60
      hostNetwork: true
      volumes:
      - name: ssl
        secret:
          secretName: traefik-cert
      - name: config
        configMap:
          name: traefik-conf
      containers:
      - image: traefik
        name: traefik-ingress-lb
        volumeMounts:
        - mountPath: "/etc/kubernetes/ssl/" #ssl路径
          name: "ssl"
        - mountPath: "/etc/k8s/conf/"  #conf路径
          name: "config"
        ports:
        - name: http
          containerPort: 80
        - name: https
          containerPort: 443
        - name: admin
          containerPort: 8080
        args:
        - --api
        - --kubernetes
        - --configfile=/etc/k8s/conf/traefik.toml
      nodeSelector:
        edgenode: "traefik-proxy" #这里限制了部署节点，应用了上次的label
---
kind: Service
apiVersion: v1
metadata:
  name: traefik-ingress-service
  namespace: kube-system
spec:
  selector:
    k8s-app: traefik-ingress-lb
  ports:
    - protocol: TCP
      port: 80
      name: web
    - protocol: TCP
      port: 443
      name: https
    - protocol: TCP
      port: 8080
      name: admin
  type: NodePort
```
应用配置：

    kubectl apply -f traefik-depoyment.yaml
- ui.yaml    
```
---
apiVersion: v1
kind: Service
metadata:
  name: traefik-web-ui
  namespace: kube-system
spec:
  selector:
    k8s-app: traefik-ingress-lb
  ports:
  - name: web
    port: 80
    targetPort: 8080

---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: traefik-web-ui
  namespace: kube-system
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  tls:
    - secretName: traefik-cert #引用证书
  rules:
  - host: tf.abcgogo.com #自己的域名
    http:
      paths:
      - path: /
        backend:
          serviceName: traefik-web-ui
          servicePort: web
```
应用配置：

    kubectl apply -f ui.yaml
检查配置输出
```
[root@master conf]# kubectl get svc,deployment,pod -o wide -n kube-system | grep traefik     

service/traefik-ingress-service   NodePort    10.68.210.65    <none>        80:34297/TCP,443:22151/TCP,8080:28570/TCP   1h        k8s-app=traefik-ingress-lb
service/traefik-web-ui            ClusterIP   10.68.138.157   <none>        80/TCP                                      1h        k8s-app=traefik-ingress-lb

pod/traefik-ingress-controller-fx5g6        1/1       Running   0          1h        192.168.2.11   192.168.2.11   <none>
pod/traefik-ingress-controller-nkhmk        1/1       Running   0          1h        192.168.2.12   192.168.2.12   <none>
pod/traefik-ingress-controller-r8hlr        1/1       Running   0          1h        192.168.2.13   192.168.2.13   <none>
```
配置好dns,就可以看到ui了 
![enter image description here](https://note.youdao.com/yws/public/resource/555b491ea64ad261ce7197126a32fa1c/xmlnote/2D56B2AE216D42E6A64BA21BA40D8B30/5907)
