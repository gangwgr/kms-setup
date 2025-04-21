1. Get IAM role of master node using console or cli.
2. put IAM role value in script and Run script aws-kms-setup.sh
Get ARN Kms values
3. Get hascode using hashcode.go 
4. Then add your hascode value and kms key arn value in plugin yaml then oc apply kms plugin
5. Check aws-kms pods should be running  
oc -n openshift-kube-apiserver get pods -l name=aws-kms-plugin -o wide
Note: KMS featuregate should be enable first
oc patch featuregate/cluster --type=merge -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["KMSEncryptionProvider"]}}}'

