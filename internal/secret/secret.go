package secret

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Protector encrypts and decrypts secrets stored at rest (e.g. webhook HMAC keys).
type Protector interface {
	Encrypt(plaintext []byte) (string, error)
	Decrypt(ciphertext string) ([]byte, error)
}

// AESGCMProtector implements Protector using AES-256-GCM.
type AESGCMProtector struct {
	aead cipher.AEAD
}

// NewAESGCMProtector creates an AES-256-GCM protector from a 32-byte key.
func NewAESGCMProtector(key []byte) (*AESGCMProtector, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("master key must be 32 bytes (got %d)", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create aes cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create gcm: %w", err)
	}
	return &AESGCMProtector{aead: aead}, nil
}

// LoadOrCreateMasterKey loads a hex-encoded 32-byte key from masterKeyHex or masterKeyFile.
// If masterKeyFile does not exist, a new random 32-byte key is generated and saved with 0600 permissions.
func LoadOrCreateMasterKey(masterKeyHex, masterKeyFile string) (*AESGCMProtector, error) {
	if strings.TrimSpace(masterKeyHex) != "" {
		raw, err := hex.DecodeString(strings.TrimSpace(masterKeyHex))
		if err != nil {
			return nil, fmt.Errorf("decode master_key_hex: %w", err)
		}
		return NewAESGCMProtector(raw)
	}
	if strings.TrimSpace(masterKeyFile) == "" {
		return nil, errors.New("master_key_hex or master_key_file is required")
	}

	rawHex, err := os.ReadFile(masterKeyFile)
	if err == nil {
		raw, decErr := hex.DecodeString(strings.TrimSpace(string(rawHex)))
		if decErr != nil {
			return nil, fmt.Errorf("decode master key file %q: %w", masterKeyFile, decErr)
		}
		return NewAESGCMProtector(raw)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read master key file %q: %w", masterKeyFile, err)
	}

	if err := os.MkdirAll(filepath.Dir(masterKeyFile), 0o700); err != nil {
		return nil, fmt.Errorf("create master key directory: %w", err)
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate master key: %w", err)
	}
	if err := os.WriteFile(masterKeyFile, []byte(hex.EncodeToString(key)+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("write master key file %q: %w", masterKeyFile, err)
	}
	return NewAESGCMProtector(key)
}

func (p *AESGCMProtector) Encrypt(plaintext []byte) (string, error) {
	nonce := make([]byte, p.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("generate nonce: %w", err)
	}
	sealed := p.aead.Seal(nonce, nonce, plaintext, nil)
	return "v1:" + base64.StdEncoding.EncodeToString(sealed), nil
}

func (p *AESGCMProtector) Decrypt(ciphertext string) ([]byte, error) {
	if !strings.HasPrefix(ciphertext, "v1:") {
		return nil, errors.New("unsupported encrypted secret format")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(ciphertext, "v1:"))
	if err != nil {
		return nil, fmt.Errorf("decode secret: %w", err)
	}
	nonceSize := p.aead.NonceSize()
	if len(raw) < nonceSize {
		return nil, errors.New("corrupt encrypted secret")
	}
	nonce, body := raw[:nonceSize], raw[nonceSize:]
	plaintext, err := p.aead.Open(nil, nonce, body, nil)
	if err != nil {
		return nil, fmt.Errorf("decrypt secret: %w", err)
	}
	return plaintext, nil
}
