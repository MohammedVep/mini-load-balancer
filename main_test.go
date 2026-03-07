package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestParseBackendWeightsDefaultsToNil(t *testing.T) {
	weights, err := parseBackendWeights("", 3)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	if weights != nil {
		t.Fatalf("expected nil weights when unset, got %v", weights)
	}
}

func TestParseBackendWeightsValid(t *testing.T) {
	weights, err := parseBackendWeights("1,3,6", 3)
	if err != nil {
		t.Fatalf("expected nil error, got %v", err)
	}
	want := []int{1, 3, 6}
	if !reflect.DeepEqual(weights, want) {
		t.Fatalf("unexpected weights: got %v want %v", weights, want)
	}
}

func TestParseBackendWeightsCountMismatch(t *testing.T) {
	_, err := parseBackendWeights("1,2", 3)
	if err == nil {
		t.Fatal("expected mismatch error")
	}
	if !strings.Contains(err.Error(), "must match backend count") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseBackendWeightsInvalidValue(t *testing.T) {
	_, err := parseBackendWeights("1,abc,3", 3)
	if err == nil {
		t.Fatal("expected parse error")
	}
	if !strings.Contains(err.Error(), "invalid backend weight") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseBackendWeightsRejectsNonPositive(t *testing.T) {
	_, err := parseBackendWeights("1,0,3", 3)
	if err == nil {
		t.Fatal("expected non-positive validation error")
	}
	if !strings.Contains(err.Error(), "must be >= 1") {
		t.Fatalf("unexpected error: %v", err)
	}
}

