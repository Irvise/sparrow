/* A small HTTP/1.1 keep-alive load generator (in the spirit of wrk).
   Usage: load PORT PATH THREADS CONNECTIONS SECONDS DEPTH
   Each thread drives CONNECTIONS/THREADS connections with epoll; each connection keeps DEPTH requests in flight
   (DEPTH 1 = no pipelining). Reports requests/s, errors and latency percentiles (DEPTH 1 only). */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int fd, in_flight;
    char buf[65536];
    int have;
    double sent_at[64];
    int sent_head, sent_tail;
} conn_t;

static int port, threads, conns, seconds, depth;
static char request[256];
static int request_len;

typedef struct {
    int index;
    long done, errors;
    double *lat;
    long lat_n, lat_cap;
} worker_t;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int open_conn(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

static void send_some(conn_t *c, int count) {
    char out[256 * 64];
    int n = 0;
    for (int i = 0; i < count; i++) {
        memcpy(out + n, request, request_len);
        n += request_len;
        c->sent_at[c->sent_tail++ % 64] = now();
    }
    int off = 0;
    while (off < n) {
        ssize_t w = write(c->fd, out + off, n - off);
        if (w <= 0) { if (errno == EINTR) continue; return; }
        off += w;
    }
    c->in_flight += count;
}

/* Parse complete responses out of the buffer; returns the number parsed, -1 on a malformed one. */
static int parse(conn_t *c, worker_t *w) {
    int parsed = 0;
    for (;;) {
        char *end = memmem(c->buf, c->have, "\r\n\r\n", 4);
        if (!end) break;
        int head_len = end - c->buf + 4;
        long length = 0;
        char *p = c->buf;
        while (p < end) {
            char *eol = memmem(p, end - p + 2, "\r\n", 2);
            if (!eol) break;
            if (eol - p > 15 && strncasecmp(p, "content-length:", 15) == 0) length = strtol(p + 15, NULL, 10);
            p = eol + 2;
        }
        if (c->have < head_len + length) break;
        if (strncmp(c->buf, "HTTP/1.1 200", 12) != 0) w->errors++;
        memmove(c->buf, c->buf + head_len + length, c->have - head_len - length);
        c->have -= head_len + length;
        double started = c->sent_at[c->sent_head++ % 64];
        if (depth == 1) {
            if (w->lat_n == w->lat_cap) { w->lat_cap *= 2; w->lat = realloc(w->lat, w->lat_cap * sizeof(double)); }
            w->lat[w->lat_n++] = now() - started;
        }
        parsed++;
    }
    return parsed;
}

static void *run(void *arg) {
    worker_t *w = arg;
    int mine = conns / threads + (w->index < conns % threads);
    int ep = epoll_create1(0);
    conn_t *cs = calloc(mine, sizeof(conn_t));
    for (int i = 0; i < mine; i++) {
        cs[i].fd = open_conn();
        if (cs[i].fd < 0) { w->errors++; continue; }
        struct epoll_event e = {.events = EPOLLIN, .data.ptr = &cs[i]};
        epoll_ctl(ep, EPOLL_CTL_ADD, cs[i].fd, &e);
        send_some(&cs[i], depth);
    }
    double stop = now() + seconds;
    struct epoll_event events[256];
    while (now() < stop) {
        int n = epoll_wait(ep, events, 256, 100);
        for (int i = 0; i < n; i++) {
            conn_t *c = events[i].data.ptr;
            ssize_t r = read(c->fd, c->buf + c->have, sizeof c->buf - c->have);
            if (r <= 0) {
                if (r < 0 && errno == EAGAIN) continue;
                w->errors++;
                epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
                close(c->fd);
                c->fd = -1;
                continue;
            }
            c->have += r;
            int got = parse(c, w);
            w->done += got;
            c->in_flight -= got;
            if (got > 0) send_some(c, got);
        }
    }
    for (int i = 0; i < mine; i++) if (cs[i].fd >= 0) close(cs[i].fd);
    return NULL;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage: load PORT PATH THREADS CONNECTIONS SECONDS DEPTH\n"); return 2; }
    port = atoi(argv[1]);
    threads = atoi(argv[3]);
    conns = atoi(argv[4]);
    seconds = atoi(argv[5]);
    depth = atoi(argv[6]);
    request_len = snprintf(request, sizeof request, "GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n", argv[2]);
    pthread_t t[256];
    worker_t w[256];
    for (int i = 0; i < threads; i++) {
        w[i] = (worker_t){.index = i, .lat_cap = 1 << 16};
        w[i].lat = malloc(w[i].lat_cap * sizeof(double));
        pthread_create(&t[i], NULL, run, &w[i]);
    }
    long done = 0, errors = 0, lat_n = 0;
    for (int i = 0; i < threads; i++) { pthread_join(t[i], NULL); done += w[i].done; errors += w[i].errors; lat_n += w[i].lat_n; }
    printf("%ld req/s  errors %ld", done / seconds, errors);
    if (depth == 1 && lat_n > 0) {
        double *all = malloc(lat_n * sizeof(double));
        long k = 0;
        for (int i = 0; i < threads; i++) { memcpy(all + k, w[i].lat, w[i].lat_n * sizeof(double)); k += w[i].lat_n; }
        qsort(all, lat_n, sizeof(double), cmp);
        printf("  p50 %.3f ms  p99 %.3f ms  max %.3f ms", all[lat_n / 2] * 1e3, all[lat_n * 99 / 100] * 1e3,
               all[lat_n - 1] * 1e3);
    }
    printf("\n");
    return 0;
}
