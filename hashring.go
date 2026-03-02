package main

import (
	"fmt"
	"hash/crc32"
	"sort"
)

type HashRing struct {
	replicas int
	keys     []uint32
	nodes    map[uint32]*Backend
}

func NewHashRing(replicas int) *HashRing {
	if replicas <= 0 {
		replicas = 100
	}
	return &HashRing{
		replicas: replicas,
		nodes:    make(map[uint32]*Backend),
	}
}

func (r *HashRing) Add(backends []*Backend) {
	r.keys = r.keys[:0]
	r.nodes = make(map[uint32]*Backend)

	for _, backend := range backends {
		for i := 0; i < r.replicas; i++ {
			key := hashString(fmt.Sprintf("%d:%s", i, backend.URL.Host))
			r.keys = append(r.keys, key)
			r.nodes[key] = backend
		}
	}
	sort.Slice(r.keys, func(i, j int) bool { return r.keys[i] < r.keys[j] })
}

func (r *HashRing) Get(key string, excluded map[*Backend]struct{}) *Backend {
	if len(r.keys) == 0 {
		return nil
	}

	hash := hashString(key)
	start := sort.Search(len(r.keys), func(i int) bool { return r.keys[i] >= hash })
	if start == len(r.keys) {
		start = 0
	}

	for i := 0; i < len(r.keys); i++ {
		backend := r.nodes[r.keys[(start+i)%len(r.keys)]]
		if backend == nil || !backend.IsAlive() || isExcluded(backend, excluded) {
			continue
		}
		return backend
	}
	return nil
}

func hashString(input string) uint32 {
	return crc32.ChecksumIEEE([]byte(input))
}
