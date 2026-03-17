# Grafana + Prometheus + Node Exporter on RHEL 9

> **Stack:** Node Exporter → Prometheus → Grafana  
> **OS:** RHEL 9 (tested on 9.x)  
> **Versions:** Node Exporter v1.8.2 · Prometheus v2.52.0 · Grafana OSS (latest via RPM repo)

---

## Prerequisites

- RHEL 9 with `sudo`/root access
- `curl`, `tar` available
- `firewalld` running (or adjust firewall steps accordingly)

---

## Step 1 — Install Node Exporter

### Download and install binary

```bash
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xvf node_exporter-1.8.2.linux-amd64.tar.gz
cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
```

### Create dedicated service user

```bash
useradd -rs /bin/false node_exporter
```

### Create systemd service

```bash
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
```

### Open firewall port

```bash
firewall-cmd --permanent --add-port=9100/tcp
firewall-cmd --reload
```

### Verify

```bash
curl -s http://localhost:9100/metrics | head -20
```

Expected: raw Prometheus metrics output (`# HELP`, `# TYPE` lines).

---

## Step 2 — Install Prometheus

### Download and install binaries

```bash
cd /tmp
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.52.0/prometheus-2.52.0.linux-amd64.tar.gz
tar xvf prometheus-2.52.0.linux-amd64.tar.gz

cp prometheus-2.52.0.linux-amd64/prometheus /usr/local/bin/
cp prometheus-2.52.0.linux-amd64/promtool /usr/local/bin/
```

### Create user and directories

```bash
useradd -rs /bin/false prometheus
mkdir -p /etc/prometheus /var/lib/prometheus

cp -r prometheus-2.52.0.linux-amd64/consoles /etc/prometheus/
cp -r prometheus-2.52.0.linux-amd64/console_libraries /etc/prometheus/

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
```

### Write scrape config

> Replace `sandbox.yikhwanz.com` with your actual hostname or IP.

```bash
cat > /etc/prometheus/prometheus.yml <<EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: 'sandbox.yikhwanz.com'
EOF
```

### Create systemd service

```bash
cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.listen-address=0.0.0.0:9090
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus
```

### Open firewall port

```bash
firewall-cmd --permanent --add-port=9090/tcp
firewall-cmd --reload
```

### Verify

Navigate to `http://<your-host>:9090/targets` — the `node` job should show **UP**.

---

## Step 3 — Install Grafana

### Add Grafana YUM repository

```bash
cat > /etc/yum.repos.d/grafana.repo <<EOF
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
```

### Install and start

```bash
dnf install grafana -y
systemctl daemon-reload
systemctl enable --now grafana-server
```

### Open firewall port

```bash
firewall-cmd --permanent --add-port=3000/tcp
firewall-cmd --reload
```

### Access Grafana

Navigate to `http://<your-host>:3000`  
Default credentials: **`admin` / `admin`** (you will be prompted to change on first login)

---

## Step 4 — Add Prometheus as Data Source

In the Grafana UI:

1. Go to **Connections → Data Sources → Add data source**
2. Select **Prometheus**
3. Set URL to: `http://localhost:9090`
4. Click **Save & Test** — response should be green ✅

---

## Step 5 — Import Node Exporter Dashboard

1. Go to **Dashboards → Import**
2. Enter Dashboard ID: **`1860`** *(Node Exporter Full — most comprehensive community dashboard)*
3. Select your Prometheus data source
4. Click **Import**

You'll get pre-built panels for:

| Category | Metrics |
|---|---|
| CPU | Usage, iowait, steal, load average |
| Memory | Used, cached, buffers, swap |
| Disk | I/O throughput, IOPS, utilization |
| Network | Bytes in/out, packets, errors |
| Filesystem | Used/free per mountpoint |
| System | Uptime, context switches, interrupts |

---

## Quick Status Check

```bash
systemctl status node_exporter prometheus grafana-server
```

All three should show `active (running)`.

---

## Port Reference

| Service | Port | Default URL |
|---|---|---|
| Node Exporter | `9100` | `http://<host>:9100/metrics` |
| Prometheus | `9090` | `http://<host>:9090` |
| Grafana | `3000` | `http://<host>:3000` |

---

## Troubleshooting

**Node Exporter not scraping:**  
Check `prometheus.yml` target matches the Node Exporter host/port. Verify with:
```bash
curl -s http://localhost:9100/metrics | grep node_exporter_build
```

**Prometheus targets page shows DOWN:**  
```bash
journalctl -u prometheus -n 50 --no-pager
```
Common cause: wrong `targets` entry in `prometheus.yml` or Node Exporter not running.

**Grafana can't reach Prometheus:**  
Ensure the data source URL uses `localhost` (not `127.0.0.1`) if both run on the same host, or use the correct IP/hostname if remote. Test reachability:
```bash
curl -s http://localhost:9090/api/v1/query?query=up
```

**SELinux blocking connections:**  
```bash
ausearch -m avc -ts recent | grep prometheus
# If blocked:
setsebool -P httpd_can_network_connect 1
```
