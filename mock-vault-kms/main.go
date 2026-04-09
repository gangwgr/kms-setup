// mock-vault-kms: a mock KMS v2 plugin based on the Kubernetes reference
// implementation (k8s.io/kms/internal/plugins/_mock). Accepts all vault-kube-kms
// command-line flags but ignores them, providing a simple AES-GCM encryption
// service so the KMS plugin lifecycle controller can be tested without a
// real Vault Enterprise instance.
//
// Reference: https://github.com/kubernetes/kms/tree/main/internal/plugins/_mock
package main

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/kms/pkg/service"
	"k8s.io/kms/pkg/util"
)

const mockKeyID = "mock-vault-kms-key-v1"

// mockVaultKMSService implements service.Service from the Kubernetes KMS
// framework. It performs local AES-256-GCM encryption with a static key.
type mockVaultKMSService struct {
	aead cipher.AEAD
}

func newMockVaultKMSService() (*mockVaultKMSService, error) {
	key := sha256.Sum256([]byte("mock-vault-kms-static-key-for-testing-only"))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, fmt.Errorf("failed to create AES cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("failed to create GCM: %w", err)
	}
	return &mockVaultKMSService{aead: aead}, nil
}

func (m *mockVaultKMSService) Status(_ context.Context) (*service.StatusResponse, error) {
	return &service.StatusResponse{
		Version: "v2",
		Healthz: "ok",
		KeyID:   mockKeyID,
	}, nil
}

func (m *mockVaultKMSService) Encrypt(_ context.Context, _ string, data []byte) (*service.EncryptResponse, error) {
	nonce := make([]byte, m.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("failed to generate nonce: %w", err)
	}
	ciphertext := m.aead.Seal(nonce, nonce, data, nil)
	return &service.EncryptResponse{
		Ciphertext: ciphertext,
		KeyID:      mockKeyID,
	}, nil
}

func (m *mockVaultKMSService) Decrypt(_ context.Context, _ string, req *service.DecryptRequest) ([]byte, error) {
	if len(req.Ciphertext) < m.aead.NonceSize() {
		return nil, fmt.Errorf("ciphertext too short")
	}
	nonce := req.Ciphertext[:m.aead.NonceSize()]
	ct := req.Ciphertext[m.aead.NonceSize():]
	plaintext, err := m.aead.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to decrypt: %w", err)
	}
	return plaintext, nil
}

var (
	listenAddr = flag.String("listen-address", "unix:///var/run/kmsplugin/kms.sock", "gRPC listen address")
	timeout    = flag.Duration("timeout", 5*time.Second, "gRPC timeout")
)

func main() {
	// All flags below match the HashiCorp vault-kube-kms binary exactly.
	// The plugin lifecycle controller passes these from the APIServer CRD;
	// this mock accepts them but ignores their values.
	_ = flag.String("vault-address", "", "(ignored) Vault server address")
	_ = flag.String("vault-namespace", "", "(ignored) Vault namespace")
	_ = flag.String("vault-connection-timeout", "10s", "(ignored) Vault connection timeout")
	_ = flag.String("transit-mount", "transit", "(ignored) Vault transit mount path")
	_ = flag.String("transit-key", "kms-key", "(ignored) Vault transit key name")
	_ = flag.String("auth-method", "approle", "(ignored) Vault auth method")
	_ = flag.String("auth-mount", "approle", "(ignored) Vault auth mount path")
	_ = flag.String("approle-role-id", "", "(ignored) Vault AppRole role ID")
	_ = flag.String("approle-secret-id-path", "", "(ignored) Path to Vault AppRole secret ID file")
	_ = flag.String("tls-ca-file", "", "(ignored) Path to Vault CA certificate")
	_ = flag.String("tls-sni", "", "(ignored) Vault TLS server name indicator")
	_ = flag.Bool("tls-skip-verify", false, "(ignored) Skip TLS verification")
	_ = flag.String("log-level", "info", "(ignored) Log level")
	_ = flag.String("metrics-port", "8080", "(ignored) Metrics/health port")
	_ = flag.Bool("disable-runtime-metrics", false, "(ignored) Disable Go runtime metrics")
	flag.Parse()

	addr, err := util.ParseEndpoint(*listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to parse endpoint: %v\n", err)
		os.Exit(1)
	}

	mockService, err := newMockVaultKMSService()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create mock KMS service: %v\n", err)
		os.Exit(1)
	}

	ctx := withShutdownSignal(context.Background())
	grpcService := service.NewGRPCService(addr, *timeout, mockService)

	fmt.Printf("mock-vault-kms: KMS v2 plugin listening on %s\n", addr)
	fmt.Printf("mock-vault-kms: key ID = %s\n", mockKeyID)
	fmt.Println("mock-vault-kms: using k8s.io/kms/pkg/service framework (Kubernetes mock reference)")
	fmt.Println("mock-vault-kms: all vault flags accepted and ignored (mock mode)")

	go func() {
		if err := grpcService.ListenAndServe(); err != nil {
			fmt.Fprintf(os.Stderr, "gRPC server error: %v\n", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	grpcService.Shutdown()
}

// withShutdownSignal returns a context that is cancelled on SIGTERM/SIGINT.
// Copied from the Kubernetes mock KMS plugin reference implementation.
func withShutdownSignal(ctx context.Context) context.Context {
	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, syscall.SIGTERM, syscall.SIGINT, os.Interrupt)

	nctx, cancel := context.WithCancel(ctx)
	go func() {
		<-signalChan
		fmt.Println("mock-vault-kms: shutting down")
		cancel()
	}()
	return nctx
}
