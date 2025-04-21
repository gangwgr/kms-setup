package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"time"

	configv1 "github.com/openshift/api/config/v1"
)

const (
	// KMSPluginEndpoint holds the unix socket path where the KMS plugin would be run
	// uniquely distinguished by the kms key id
	KMSPluginEndpoint = "unix:///var/kube-kms/%s/socket.sock"

	// KMSPluginTimeout fixed timeout
	KMSPluginTimeout = 5 * time.Second
)

// EncodeKMSConfig encodes kms config into json format
func EncodeKMSConfig(config *configv1.KMSConfig) ([]byte, error) {
	return json.Marshal(config)
}

// hashKMSConfig returns a short FNV 64-bit hash for a KMSConfig struct
func hashKMSConfig(config configv1.KMSConfig) (string, error) {
	hasher := fnv.New64a()
	hasher.Reset()

	encoded, err := EncodeKMSConfig(&config)
	if err != nil {
		return "", fmt.Errorf("could not generate hash for KMS config: %v", err)
	}

	fmt.Fprintf(hasher, "%s", encoded)
	return hex.EncodeToString(hasher.Sum(nil)[0:]), nil
}

// GenerateKMSKeyId generates a hash-ed KMS key id appended with an id integer
func GenerateKMSKeyId(kmsConfig configv1.KMSConfig, nonce uint64) (string, error) {
	hash, err := hashKMSConfig(kmsConfig)
	if err != nil {
		return "", fmt.Errorf("could not generate KMS config hash: %v", err)
	}
	return fmt.Sprintf("%s-%d", hash, nonce), nil
}

func main() {
	keyId, err := GenerateKMSKeyId(configv1.KMSConfig{
		Type: configv1.AWSKMSProvider,
		AWS: &configv1.AWSKMSConfig{
			KeyARN: "arn:aws:kms:us-east-2:301721915996:key/f319b2a3-ddcd-48ce-bda2-e45d401a3b40",
			Region: "us-east-2",
		},
	}, 1)
	if err != nil {
		panic(err)
	}
	fmt.Println(keyId)
}

