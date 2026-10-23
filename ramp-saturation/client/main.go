// A load generator in the manner of Anton Putra's lesson 228: workers loop
// SET of a small JSON user then GET of the same key, sleep, and do it again;
// workers are added in stages, so the load offered rises step by step and
// latency, throughput, errors and the servers' CPU and memory can be watched
// up to where each server can take no more.
//
// Configured from the environment (see the env* calls in main); metrics are
// served for Prometheus on :8081/metrics.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	mrand "math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

type User struct {
	UUID      string `json:"uuid"`
	Username  string `json:"username"`
	FirstName string `json:"firstName"`
	LastName  string `json:"lastName"`
	Address   string `json:"address"`
}

func randHex(n int) string {
	b := make([]byte, (n+1)/2)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)[:n]
}

func newUser() User {
	return User{
		UUID:      randHex(32),
		Username:  randHex(10),
		FirstName: randHex(5),
		LastName:  randHex(10),
		Address:   randHex(20),
	}
}

func envStr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			log.Fatalf("%s: %v", k, err)
		}
		return n
	}
	return def
}

var (
	duration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "client_request_duration_seconds",
		Help:    "Time a request (or a pipelined batch) took, as the client saw it.",
		Buckets: prometheus.ExponentialBucketsRange(0.00002, 2, 60),
	}, []string{"db", "op"})
	requests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "client_requests_total",
		Help: "Requests made, by outcome.",
	}, []string{"db", "op", "status"})
	workers = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_workers",
		Help: "Workers (concurrent clients) this pod is running.",
	}, []string{"db"})
	stage = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "client_stage",
		Help: "Stage of the ramp this pod is in.",
	}, []string{"db"})
)

func main() {
	db := envStr("DB_NAME", "redis")
	// DB_ADDRS: a comma-separated list (a cluster's seed nodes); DB_ADDR: one.
	addrs := strings.Split(envStr("DB_ADDRS", envStr("DB_ADDR", "127.0.0.1:6379")), ",")
	cluster := envStr("CLUSTER", "0") == "1"
	start := envInt("START_CLIENTS", 10)
	step := envInt("STEP_CLIENTS", 10)
	maxClients := envInt("MAX_CLIENTS", 500)
	stageSeconds := envInt("STAGE_SECONDS", 30)
	// Sleep between one request (or batch) and the next, per worker: each
	// worker offers about 1/(delay + latency) of them a second.
	delay := time.Duration(envInt("REQUEST_DELAY_MS", 0)) * time.Millisecond
	ttl := time.Duration(envInt("TTL_SECONDS", 20)) * time.Second
	// PIPELINE > 1: that many SET+GET pairs in one round trip; every command
	// counts towards throughput, and the latency is the batch's round trip.
	pipeline := envInt("PIPELINE", 1)
	// KEYSPACE > 0: keys user:0..N-1 at random (a fixed dataset); 0: a new
	// UUID per pair.
	keyspace := envInt("KEYSPACE", 0)
	// A request not answered in this long fails, and counts as an error.
	timeout := time.Duration(envInt("TIMEOUT_MS", 1000)) * time.Millisecond
	// Unix time to start the ramp at, so every pod of every database starts
	// together; 0 starts at once.
	startAt := envInt("START_AT", 0)

	reg := prometheus.NewRegistry()
	reg.MustRegister(duration, requests, workers, stage)
	go func() {
		http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
		log.Fatal(http.ListenAndServe(":8081", nil))
	}()

	var rdb redis.UniversalClient
	if cluster {
		rdb = redis.NewClusterClient(&redis.ClusterOptions{
			Addrs:        addrs,
			PoolSize:     maxClients + 10,
			DialTimeout:  5 * time.Second,
			ReadTimeout:  timeout,
			WriteTimeout: timeout,
		})
	} else {
		rdb = redis.NewClient(&redis.Options{
			Addr:         addrs[0],
			PoolSize:     maxClients + 10,
			DialTimeout:  5 * time.Second,
			ReadTimeout:  timeout,
			WriteTimeout: timeout,
		})
	}
	ctx := context.Background()
	if os.Getenv("FLUSH_ONLY") == "1" {
		var err error
		if c, ok := rdb.(*redis.ClusterClient); ok {
			err = c.ForEachMaster(ctx, func(ctx context.Context, m *redis.Client) error {
				return m.FlushAll(ctx).Err()
			})
		} else {
			err = rdb.FlushAll(ctx).Err()
		}
		if err != nil {
			log.Fatalf("FLUSHALL %v: %v", addrs, err)
		}
		log.Printf("flushed %v", addrs)
		return
	}
	workers.WithLabelValues(db).Set(0)

	// Values made once: the same shape as the lesson's users, so the work
	// per request on the client is a copy, not JSON and random numbers.
	values := make([][]byte, 1024)
	for i := range values {
		values[i], _ = json.Marshal(newUser())
	}
	keyOf := func() string {
		if keyspace > 0 {
			return "user:" + strconv.Itoa(mrand.IntN(keyspace))
		}
		return randHex(32)
	}

	if wait := time.Until(time.Unix(int64(startAt), 0)); startAt > 0 && wait > 0 {
		log.Printf("starting in %s", wait.Round(time.Second))
		time.Sleep(wait)
	}

	setDur := duration.WithLabelValues(db, "set")
	getDur := duration.WithLabelValues(db, "get")
	okSet := requests.WithLabelValues(db, "set", "ok")
	okGet := requests.WithLabelValues(db, "get", "ok")
	badSet := requests.WithLabelValues(db, "set", "error")
	badGet := requests.WithLabelValues(db, "get", "error")

	work := func() {
		sets := make([]*redis.StatusCmd, pipeline)
		gets := make([]*redis.StringCmd, pipeline)
		for {
			if pipeline <= 1 {
				k, v := keyOf(), values[mrand.IntN(len(values))]
				t := time.Now()
				if err := rdb.Set(ctx, k, v, ttl).Err(); err != nil {
					badSet.Inc()
				} else {
					setDur.Observe(time.Since(t).Seconds())
					okSet.Inc()
				}
				t = time.Now()
				if err := rdb.Get(ctx, k).Err(); err != nil {
					badGet.Inc()
				} else {
					getDur.Observe(time.Since(t).Seconds())
					okGet.Inc()
				}
			} else {
				p := rdb.Pipeline()
				for i := 0; i < pipeline; i++ {
					k := keyOf()
					sets[i] = p.Set(ctx, k, values[mrand.IntN(len(values))], ttl)
					gets[i] = p.Get(ctx, k)
				}
				t := time.Now()
				_, _ = p.Exec(ctx)
				took := time.Since(t).Seconds()
				var sOK, gOK, sBad, gBad float64
				for i := 0; i < pipeline; i++ {
					if sets[i].Err() != nil {
						sBad++
					} else {
						sOK++
					}
					if gets[i].Err() != nil {
						gBad++
					} else {
						gOK++
					}
				}
				if sOK > 0 {
					setDur.Observe(took)
				}
				if gOK > 0 {
					getDur.Observe(took)
				}
				okSet.Add(sOK)
				okGet.Add(gOK)
				badSet.Add(sBad)
				badGet.Add(gBad)
			}
			if delay > 0 {
				time.Sleep(delay)
			}
		}
	}

	n, s := 0, 0
	target := start
	for {
		for n < target {
			go work()
			n++
		}
		workers.WithLabelValues(db).Set(float64(n))
		stage.WithLabelValues(db).Set(float64(s))
		log.Printf("stage %d: %d workers", s, n)
		time.Sleep(time.Duration(stageSeconds) * time.Second)
		if n >= maxClients {
			continue // hold at the top until the pod is stopped
		}
		s++
		target = n + step
		if target > maxClients {
			target = maxClients
		}
	}
}
