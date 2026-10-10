<h1 align="center">Authentik</h1>

[Sekilas Tentang](#sekilas-tentang) | [Instalasi](#instalasi) | [Konfigurasi](#konfigurasi) | [Otomatisasi](#otomatisasi) | [Cara Pemakaian](#cara-pemakaian) | [Pembahasan](#pembahasan) | [Referensi](#referensi)
:---:|:---:|:---:|:---:|:---:|:---:|:---:

<!-- TODO: isi nama kelompok dan anggota -->



# Sekilas Tentang
[`^ kembali ke atas ^`](#)

**Authentik** adalah *identity provider* (IdP) *open source* yang menyediakan *single sign-on* (SSO), *multi-factor authentication* (MFA), dan manajemen pengguna terpusat. Dengan Authentik, pengguna cukup login satu kali untuk mengakses banyak aplikasi, dan administrator dapat mengatur hak akses dari satu tempat.

<!-- TODO: sejarah singkat, pengembang, lisensi -->
<!-- TODO: tech stack (backend Python/Django, database PostgreSQL) - cek dokumentasi resmi -->

### Mengapa Penting
- Satu login untuk banyak aplikasi (SSO)
- Kontrol akses terpusat berdasarkan pengguna, grup, dan kebijakan
- MFA dapat diterapkan pada aplikasi yang tidak punya MFA sendiri
- Semua aktivitas login tercatat pada *audit log*

### Arsitektur

Authentik terdiri dari beberapa komponen yang dijalankan sebagai kontainer:

- **server**: antarmuka web, API, dan *login flow*
- **worker**: tugas latar belakang (email, blueprint, pembersihan data)
- **PostgreSQL**: penyimpanan pengguna, grup, *flow*, kebijakan, dan *audit log*
- **Outpost** (opsional): kontainer *proxy* untuk melindungi aplikasi lain

<!-- TODO: cek docker-compose.yml versi terbaru (apakah masih memakai Redis?) -->
<!-- TODO: diagram arsitektur (browser -> Caddy -> server/worker -> database) -->

### Komponen Pendukung pada Demo

Authentik paling mudah dipahami jika ada aplikasi yang dilindunginya. Pada demo ini ditambahkan tiga komponen ke *stack* yang sama:

#### Caddy (reverse proxy)
**Caddy** adalah *web server* modern yang dapat berperan sebagai *reverse proxy*: satu pintu masuk yang menerima semua permintaan dari browser lalu meneruskannya ke kontainer yang tepat berdasarkan nama host. Peran Caddy pada demo ini:
- Menjadi **titik masuk HTTPS** tunggal untuk tiga nama host publik.
- Pada **VPS dengan IP publik** (Opsi A), Caddy mengambil sertifikat publik otomatis lewat ACME (Let's Encrypt) dan meneruskan trafik ke container di belakangnya.
- Pada **komputer lokal via Cloudflare Tunnel** (Opsi B), HTTPS dihentikan di edge Cloudflare; Caddy menerima HTTP internal dari `cloudflared` dan meneruskan ke container (file `Caddyfile.tunnel`).
- Menjadi **penjaga pintu** untuk aplikasi yang tidak punya login sendiri (*forward auth*, lihat di bawah), sehingga port internal aplikasi tidak perlu diekspos.

Caddy **tidak wajib** untuk menjalankan Authentik, tetapi diperlukan agar demo HTTPS dan *forward auth* berjalan.

#### IT-Tools (contoh aplikasi tanpa login: forward auth)
**IT-Tools** adalah kumpulan alat bantu developer berbasis web (konversi base64, pembuat hash, generator UUID, dan sebagainya). Aplikasinya statis, sangat ringan, dan **tidak punya sistem login sama sekali**. Karena itu ia cocok untuk mendemokan bahwa Authentik dapat melindungi aplikasi apa pun, bahkan yang tidak tahu apa-apa soal autentikasi.

#### Poznote (contoh aplikasi dengan akun pengguna: OIDC)
**Poznote** adalah aplikasi catatan modern yang mendukung login lewat OIDC. Setiap pengguna memiliki workspace sendiri dengan catatan terpisah, sehingga jelas terlihat bahwa login melalui Authentik membuat akun individual untuk tiap orang.

#### Forward auth vs OIDC

| | Forward auth | OIDC (OpenID Connect) |
|---|---|---|
| Analogi | Satpam di pintu masuk | Tombol "Login dengan Google" |
| Aplikasi harus mendukung? | Tidak | Ya |
| Akun per pengguna di aplikasi | Tidak (hanya header identitas) | Ya |
| Yang bekerja | Caddy + Authentik | Aplikasi + Authentik |
| Contoh pada demo | IT-Tools | Poznote |

<!-- TODO: diagram alur kedua mekanisme -->



# Instalasi
[`^ kembali ke atas ^`](#)

#### Kebutuhan Sistem :
- Server: VPS Debian 12+ / Ubuntu 22.04+ dengan **IP publik** (Opsi A), ATAU komputer lokal Debian/Ubuntu (Opsi B)
- RAM minimal 2 GB (disarankan 3-4 GB jika demo Caddy + IT-Tools + Poznote ikut dijalankan)
- CPU 2 core
- Disk 20 GB
- Docker Engine dan Docker Compose plugin — semua deployment butuh Compose >= 2.24.4: tag `!override` dipakai di **kedua** overlay (`docker-compose.vps.yml` dan `docker-compose.tunnel.yml`), `!reset` di overlay tunnel. Lihat [Docker: Merge Compose files](#referensi).
- Satu domain dengan DNS yang Anda kelola; tiga subdomain untuk Authentik, IT-Tools, dan Poznote

#### Langkah Bersama: Instal Docker

1. Login ke server/komputer.
    ```
    $ ssh user@<ip-server>
    ```

2. Instal Docker dari repositori resmi Docker (bukan `docker.io` bawaan distro). **Bila sebelumnya sudah pernah memasang Docker**, hapus dulu paket bawaan yang bentrok:
    ```
    $ sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc | cut -f1)
    ```
    Daftar mengikuti instruksi resmi Docker; `dpkg --get-selections` hanya menyertakan paket yang benar-benar terpasang (`apt` boleh melaporkan bahwa sebagian paket tidak ada — aman diabaikan). Perintah ini **hanya menghapus paket, tidak menghapus data**: kontainer, image, dan volume lama tetap di `/var/lib/docker`, jadi tidak ada container Authentik/Postgres yang hilang.
    ```
    $ sudo apt-get update
    $ sudo apt-get install -y ca-certificates curl gnupg
    $ sudo install -m 0755 -d /etc/apt/keyrings
    $ sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
    $ sudo chmod a+r /etc/apt/keyrings/docker.asc
    $ . /etc/os-release
    $ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list
    $ sudo apt-get update
    $ sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ```
    `$ID` menyesuaikan repo Docker secara otomatis (`debian` di Debian, `ubuntu` di Ubuntu), dan `${UBUNTU_CODENAME:-$VERSION_CODENAME}` memilih suite yang benar di kedua distro. Versi Ubuntu yang didukung Docker: 22.04 (jammy), 24.04 (noble), dan 26.04 (resolute).

3. Unduh `docker-compose.yml` resmi Authentik.
    ```
    $ sudo mkdir -p /opt/authentik
    $ sudo curl -fsSL -o /opt/authentik/docker-compose.yml https://docs.goauthentik.io/compose.yml
    ```

Nama host contoh di bawah (`auth.example.com`, `tools.example.com`, `poznote.example.com`) hanyalah contoh, bukan nilai harfiah. Gunakan tiga FQDN yang berbeda di domain Anda: mis. `auth.<domain>`, `tools.<domain>`, `poznote.<domain>`, dan gunakan nilainya secara konsisten di `.env`, DNS, dan pengaturan provider. Bila sebuah label sudah dipakai record lain, jangan ditimpa: pilih label lain (mis. tambah `-demo`).

<!-- TODO: screenshot setiap langkah, seperti pada contoh laporan -->

#### Opsi A: VPS dengan IP Publik (Caddy langsung + ACME)

Cukup untuk VPS dengan IP publik dan inbound 80/443 terbuka. Caddy mengambil sertifikat publik otomatis lewat ACME (Let's Encrypt); tidak ada layanan tunnel.

1. Buat tiga DNS record `A`/`AAAA` yang mengarah ke IP publik VPS, satu untuk tiap nama host. Tunggu DNS menyebar (cek dengan `dig +short <host>`).

2. Dari **direktori repo** (tempat file konfigurasi ini berada), salin konfigurasi ke `/opt/authentik`, lalu buat dan isi `.env`:
    ```
    $ sudo cp docker-compose.override.yml docker-compose.vps.yml Caddyfile /opt/authentik/
    $ cd /opt/authentik
    $ echo "PG_PASS=$(openssl rand -base64 36 | tr -d '\n')" | sudo tee .env
    $ echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" | sudo tee -a .env
    $ sudo nano .env
    ```
    Di editor, tambahkan baris berikut (ganti nama host contoh dengan nama host pilihan Anda):
    ```
    COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.vps.yml
    AUTH_PUBLIC_HOST=auth.example.com
    TOOLS_PUBLIC_HOST=tools.example.com
    POZNOTE_PUBLIC_HOST=poznote.example.com
    ```
    Kredensial OIDC Poznote (`POZNOTE_OIDC_CLIENT_ID`/`SECRET`) diisi setelah provider OAuth2 dibuat di Authentik (bagian Cara Pemakaian), lalu disalin ke `.env`. Lalu kunci izin file secret:
    ```
    $ sudo chmod 600 .env
    ```

3. Validasi, lalu jalankan **hanya backend** dulu (Caddy belum, jadi belum ada ingress publik sama sekali):
    ```
    $ sudo docker compose config --quiet
    $ sudo docker compose pull
    $ sudo docker compose up -d server worker poznote it-tools
    ```
    Jangan pernah mencetak `docker compose config` tanpa `--quiet` di mesin berisi secret asli. Konfirmasi Authentik sehat sebelum lanjut:
    ```
    $ curl -fsS http://127.0.0.1:9000/-/health/live/
    ```

4. Dari komputer yang menjalankan browser, buka SSH *port forward* (halaman ini hanya lewat SSH, tidak dipublikasikan):
    ```
    $ ssh -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 user@<ip-server>
    ```
    - Buka `http://localhost:9000/if/flow/initial-setup/` dan buat kata sandi admin Authentik yang kuat.
    - Buka `http://localhost:8040`, login Poznote sebagai `admin_change_me` / `admin`, ganti **username dan password** administratornya di UI Poznote, lalu **logout dan pastikan kredensial lama ditolak**.

    **Jangan lanjut ke langkah berikutnya sebelum kedua akun di atas selesai diganti dan kredensial bawaan Poznote terbukti tidak bisa login lagi.** Panduan MFA di bagian Konfigurasi tetap berlaku.

5. Buka ingress publik di firewall VPS: izinkan inbound 80 dan 443 (Caddy + ACME) serta SSH dari jaringan administrasi. Jangan buka inbound 9000/9443/8040, binding Docker sudah di-loopback.

6. Jalankan stack penuh. Caddy baru mulai sekarang, setelah kredensial default tidak lagi berlaku:
    ```
    $ sudo docker compose up -d
    ```
    Sertifikat ACME diterbitkan saat permintaan pertama; jika gagal, cek log Caddy: `sudo docker compose logs caddy`. Verifikasi kontainer: `sudo docker compose ps`. Lanjutkan ke bagian [Cara Pemakaian](#cara-pemakaian).

#### Catatan Keamanan Instalasi
- Hanya Caddy (port 80/443) pada Opsi A yang menjadi titik masuk; port bawaan aplikasi (9000/9443/8040) hanya terikat ke loopback.
- Simpan `.env` (dan `cloudflared.env` pada Opsi B) dengan izin `600` dan jangan pernah dimasukkan ke git (sudah ada di `.gitignore`).
- Port yang dipublikasikan Docker dapat melewati aturan `ufw`; verifikasi dengan `nmap` dari mesin lain.
- Buat kata sandi admin sendiri saat *initial setup*, jangan ditulis di dalam file konfigurasi.
- Tetapkan versi *image* (jangan `latest`) untuk penggunaan di luar demo.

<!-- TODO: hasil pengujian nmap -->



#### Opsi B: Komputer Lokal via Cloudflare Tunnel

Untuk komputer lokal **tanpa IP publik dan tanpa port forwarding di router**: `cloudflared` melakukan koneksi *outbound* ke Cloudflare, HTTPS dihentikan di edge Cloudflare, dan Caddy dihubungi lewat jaringan internal Compose. Syarat: domain yang dikelola akun Cloudflare Anda. Selesaikan dulu Langkah Bersama di atas, lalu lanjut:

1. Dari **direktori repo**, salin konfigurasi ke `/opt/authentik`, lalu buat dan isi `.env`:
    ```
    $ sudo cp docker-compose.override.yml docker-compose.tunnel.yml Caddyfile.tunnel /opt/authentik/
    $ cd /opt/authentik
    $ echo "PG_PASS=$(openssl rand -base64 36 | tr -d '\n')" | sudo tee .env
    $ echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" | sudo tee -a .env
    $ sudo nano .env
    ```
    Di editor, tambahkan baris berikut (ganti nama host contoh dengan nama host pilihan Anda):
    ```
    COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.tunnel.yml
    AUTH_PUBLIC_HOST=auth.example.com
    TOOLS_PUBLIC_HOST=tools.example.com
    POZNOTE_PUBLIC_HOST=poznote.example.com
    ```
    Kredensial OIDC Poznote (`POZNOTE_OIDC_CLIENT_ID`/`SECRET`) diisi setelah provider OAuth2 dibuat di Authentik (bagian Cara Pemakaian), lalu disalin ke `.env`. `COMPOSE_FILE` membuat overlay tunnel selalu aktif untuk setiap perintah `docker compose` dari direktori ini; jangan simpan `COMPOSE_PROFILES=tunnel` (konektor sengaja tidak ikut `up -d` biasa). Buat juga file token konektor (kosong dulu) milik root:
    ```
    $ sudo touch cloudflared.env && sudo chmod 600 cloudflared.env
    $ sudo chmod 600 .env
    ```

2. Validasi dan jalankan stack (konektor belum dibuat karena profile `tunnel` tidak aktif):
    ```
    $ sudo docker compose config --quiet
    $ sudo docker compose pull
    $ sudo docker compose up -d
    ```
    Jangan pernah mencetak `docker compose config` tanpa `--quiet` di mesin berisi secret asli. Konfirmasi Authentik sehat sebelum lanjut:
    ```
    $ curl -fsS http://127.0.0.1:9000/-/health/live/
    ```

3. Dari komputer yang menjalankan browser, buka SSH *port forward* (halaman ini hanya lewat SSH, tidak dipublikasikan ke jaringan):
    ```
    $ ssh -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 user@<ip-komputer>
    ```
    - Buka `http://localhost:9000/if/flow/initial-setup/` dan buat kata sandi admin Authentik yang kuat.
    - Buka `http://localhost:8040`, login Poznote sebagai `admin_change_me` / `admin`, lalu ganti **username dan password** administratornya di UI Poznote. Pastikan kredensial lama tidak bisa login lagi.

    **Aktivasi tunnel dilarang sebelum kedua akun di atas selesai diganti.** Panduan MFA di bagian Konfigurasi tetap berlaku.

4. Di dashboard Cloudflare (Zero Trust > Networks > Tunnels) buat satu tunnel *remotely managed* bernama `authentik-demo`. Simpan token tunnel sebagai `TUNNEL_TOKEN=<token-asli>` di `/opt/authentik/cloudflared.env` **menggunakan editor**, bukan argumen command-line atau assignment shell yang masuk riwayat shell:
    ```
    $ sudo nano /opt/authentik/cloudflared.env
    ```
    Buat tiga *public hostname* di tunnel tersebut, masing-masing satu nama host pilihan Anda, *Service type* **HTTP** dengan URL `caddy:80`, tanpa path. Biarkan *HTTP Host Header override* kosong agar Host publik asli sampai ke Caddy; **jangan** aktifkan *No TLS Verify* (origin memang HTTP). Biarkan dashboard membuat CNAME untuk tiap hostname.

5. **Wajib**: pastikan HTTP publik dialihkan ke HTTPS di edge. Caddyfile.tunnel melayani origin HTTP dan tidak melakukan redirect sendiri; tanpa rule ini, kredensial bisa dikirim lewat HTTP polos. Kecuali Anda sudah punya kebijakan HTTPS cakup-host yang setara di zone, buat **Single Redirect** rule untuk tiap hostname: *Request URL* wildcard `http://<host>/*`, *Target URL* `https://<host>/${1}`, status `301`, *Preserve query string* aktif. Cakupan rule hanya host-host ini; jangan mengubah kebijakan HTTPS layanan lain di zone. Tunggu *edge certificate* tiap hostname aktif sebelum langkah 6. Tidak ada layer login Cloudflare Access tambahan, autentikasi demo tetap di Authentik/Poznote.

6. Aktifkan konektor setelah kedua akun admin diganti **dan redirect/certificate edge di langkah 5 sudah aktif**:
    ```
    $ sudo docker compose --profile tunnel pull cloudflared
    $ sudo docker compose --profile tunnel up -d cloudflared
    ```
    Pantau status **Healthy** dan log konektor di dashboard sebelum mengonfigurasi integrasi publik di bagian Cara Pemakaian. IT-Tools tetap tertutup (*fails closed*) sampai provider-nya dibuat.

7. Jaringan: tetap nonaktifkan *port forwarding* 80/443 di router. Firewall cukup mengizinkan *outbound* DNS, HTTPS (*pull image*, discovery OIDC Poznote), dan TCP/UDP 7844 untuk Cloudflare Tunnel; pertahankan SSH dari jaringan administrasi; **jangan** buka inbound 80/443/9000/9443/8040. Isolasi ingress mengandalkan binding Docker yang dihapus/di-loopback (`docker-compose.tunnel.yml`), bukan `ufw` saja. Internet, waktu aktif komputer, dan konektor adalah prasyarat ketersediaan publik.

    Pindah antar opsi: pertahankan secret `.env` dan *named volume* (`down -v` dilarang, jangan regenerasi `AUTHENTIK_SECRET_KEY`), salin overlay + Caddyfile opsi tujuan, set `COMPOSE_FILE` yang sesuai, lalu `sudo docker compose up -d` untuk mengganti binding. Selesaikan penggantian akun admin yang belum diganti lewat SSH loopback sebelum mengaktifkan kembali ingress publik.

#### Menyalakan/Mematikan VM

Semua layanan (termasuk `cloudflared`) memakai `restart: unless-stopped`. Docker memulainya otomatis saat VM menyala, selama Docker daemon ikut aktif (default di Debian/Ubuntu setelah instalasi via repositori resmi).

**Menyalakan kembali VM yang dimatikan:**
1. Nyalakan VM, tunggu boot selesai. Kontainer yang **pernah dibuat/jalan** otomatis menyala (`restart: unless-stopped` tidak bisa membuat layanan yang belum pernah di-`up` atau sudah di-`down`, itu butuh `up -d` manual).
2. (Opsional) Verifikasi aplikasi hidup:
   ```
   $ cd /opt/authentik
   $ sudo docker compose ps        # semua baris "Up"
   $ curl -fsS http://127.0.0.1:9000/-/health/live/ && echo OK
   ```
3. **Opsi B saja:** cek dashboard Cloudflare, status tunnel kembali **Healthy** dalam 1-2 menit setelah konektor terhubung. Selama VM mati, hostname publik memang tidak bisa diakses (530/timeout di Cloudflare), wajar, tidak ada data yang rusak. **Opsi A:** cek `https://<AUTH_PUBLIC_HOST>/` terbuka; sertifikat ACME sudah tersimpan di volume `caddy_data` dan tidak diterbitkan ulang.

   > **Opsi B, konektor yang pernah di-`stop` manual:** `up -d` biasa **tidak** menghidupkan `cloudflared`, layanan ber-*profile* hanya aktif lewat profile-nya. Urutan pemulihan lengkap:
   > ```
   > $ cd /opt/authentik && sudo docker compose up -d          # aplikasi
   > $ curl -fsS http://127.0.0.1:9000/-/health/live/ && echo OK
   > $ sudo docker compose --profile tunnel up -d cloudflared  # konektor
   > ```

**Mematikan VM dengan aman:**
```
$ sudo shutdown -h now
```
Jangan pakai "power off" langsung di VirtualBox/panel VPS, *sudden power loss* berisiko korupsi pada database PostgreSQL/SQLite yang sedang menulis. `shutdown` menghentikan kontainer dengan rapi lebih dulu.

**Pengecualian `unless-stopped`:** jika Anda pernah menjalankan `sudo docker compose stop <layanan>` secara manual, layanan itu TIDAK akan menyala otomatis saat VM restart, status "stopped"-nya menempel. Jalankan `sudo docker compose up -d <layanan>` sekali (konektor: `--profile tunnel up -d cloudflared`) untuk menghidupkannya dan mengembalikan auto-start.

**Opsi A vs B, ketersediaan:** publik hanya bisa mengakses saat VM/VPS menyala, kedua opsi sama-sama down saat mesin mati. Bedanya Opsi A (VPS) biasanya memang dirancang menyala terus; Opsi B (komputer lokal) mengikuti jadwal Anda. Bila demo perlu tersedia sepanjang presentasi, nyalakan mesin sebelumnya dan verifikasi langkah di atas; untuk ketersediaan 24/7 pindah ke Opsi A.

# Konfigurasi
[`^ kembali ke atas ^`](#)

- **Pengguna dan grup**: membuat pengguna dan grup uji <!-- TODO: langkah + screenshot -->
- **MFA untuk admin** (TOTP atau WebAuthn) <!-- TODO -->
- **Branding dan *login flow* bawaan** <!-- TODO -->
- **Pengaturan email** (opsional, untuk pemulihan kata sandi) <!-- TODO -->

#### Konsep Utama
- **Flow**: urutan langkah proses (login, pendaftaran, pemulihan) <!-- TODO: lengkapi -->
- **Stage**: satu langkah di dalam *flow* (mis. input password, MFA) <!-- TODO -->
- **Policy**: aturan yang menentukan akses atau kelanjutan *flow* <!-- TODO -->
- **Provider**: protokol yang dipakai aplikasi (OIDC, SAML, LDAP, proxy) <!-- TODO -->
- **Application**: aplikasi yang dilindungi, terhubung ke satu *provider* <!-- TODO -->
- **Outpost**: komponen tambahan untuk *proxy/LDAP* <!-- TODO -->

#### Konfigurasi Caddy
Ada dua file Caddy, satu per opsi hosting, keduanya membaca nama host dari environment variable Caddy (`AUTH_PUBLIC_HOST`, `TOOLS_PUBLIC_HOST`, `POZNOTE_PUBLIC_HOST` di `.env`):

| File | Opsi | Perbedaan |
|---|---|---|
| [`Caddyfile`](Caddyfile) | A (VPS, IP publik) | Alamat situs tanpa skema → Caddy mengambil sertifikat publik ACME otomatis dan mengalihkan HTTP ke HTTPS; mempublikasikan 80/443 |
| [`Caddyfile.tunnel`](Caddyfile.tunnel) | B (lokal, Cloudflare Tunnel) | Alamat situs `http://…` eksplisit; Caddy tanpa port publik, hanya dihubungi `cloudflared` lewat jaringan internal; memercayai header `X-Forwarded-*` dari jaringan internal (`trusted_proxies static private_ranges`) |

Rutenya sama di kedua file:

| Host | Diteruskan ke | Fungsi |
|---|---|---|
| `<AUTH_PUBLIC_HOST>` | `server:9000` | Antarmuka Authentik |
| `<TOOLS_PUBLIC_HOST>` | `it-tools:80` | IT-Tools, dilindungi *forward auth* |
| `<POZNOTE_PUBLIC_HOST>` | `poznote:80` | Poznote, login lewat OIDC |

Pada blok IT-Tools, handler dibungkus `route` dengan urutan: (1) path `/outpost.goauthentik.io/*` diteruskan ke outpost, (2) `forward_auth` bertanya ke Authentik apakah pengguna sudah login sebelum permintaan diteruskan ke IT-Tools, sambil menyalin header identitas (`X-Authentik-Username`, dll.) ke aplikasi, (3) `reverse_proxy` ke IT-Tools. Sesuai template Caddy resmi Authentik.



# Otomatisasi
[`^ kembali ke atas ^`](#)

Dengan otomatisasi, seluruh instalasi dan konfigurasi dapat direproduksi.

#### Cara 1: Shell script
Jalankan [setup.sh](setup.sh) pada server Debian/Ubuntu baru (dengan `docker-compose.override.yml`, `docker-compose.vps.yml`/`docker-compose.tunnel.yml`, `Caddyfile`/`Caddyfile.tunnel` di folder yang sama). Bila file belum *executable* (mis. diunduh tanpa izin git), beri izin dulu: `chmod +x setup.sh`. Script ini menggantikan seluruh Langkah Bersama + langkah `.env`/salin file pada Opsi A/B di atas:
```
$ sudo ./setup.sh --vps auth.example.com tools.example.com poznote.example.com --harden
$ sudo ./setup.sh --tunnel auth.example.com tools.example.com poznote.example.com --harden
```
- `--vps` / `--tunnel`: pilih mode hosting sesuai bagian Instalasi; tiga argumen host adalah FQDN publik Anda.
- `--harden`: mengatur `ufw` (SSH + inbound 80/443 hanya untuk `--vps`), `unattended-upgrades`, dan `fail2ban`. Di Ubuntu, `fail2ban` ada di komponen `universe` (aktif secara default); bila sources Anda sudah dikustom dan `universe` tidak aktif, aktifkan dulu: `sudo add-apt-repository universe`.

Deteksi OS di dalam script menerima `debian` maupun `ubuntu`, dan repo Docker dipilih otomatis (`linux/${ID}` + suite `${UBUNTU_CODENAME:-$VERSION_CODENAME}`), persis seperti instruksi resmi Docker: Ubuntu 22.04 (jammy), 24.04 (noble), 26.04 (resolute), serta Debian 12 (bookworm)/13 (trixie) keduanya didukung Docker tanpa perubahan script.

Script melakukan: pengecekan awal, instalasi Docker dari repo resmi, *hardening* dasar (opsional), lalu **menjalankan seluruh backend privat** (`server`, `worker`, `poznote`, `it-tools`) dan menunggu sampai Authentik sehat. Ia tidak pernah membuka ingress publik sendiri; akun admin harus di-*bootstrap* lewat SSH *port-forward* dulu, baru Caddy/konektor dijalankan manual seperti yang dicetak di akhir script. Script bersifat *idempotent*: dijalankan ulang tidak akan mengganti *secret* atau file konfigurasi yang sudah ada, dan menolak `COMPOSE_FILE` `.env` yang tidak memilih overlay mode yang diminta.

#### Cara 2: Compose deklaratif
Seluruh *stack* juga tergambar sebagai file deklaratif: `docker-compose.override.yml` + overlay (`docker-compose.vps.yml` atau `docker-compose.tunnel.yml`) + Caddyfile. Cukup `docker compose up -d` untuk mereproduksi instalasi di server baru.

#### Blueprint (opsi ketiga, opt-in: konfigurasi sebagai kode)
Instalasi manual di Opsi A/B **tidak memakai blueprint**. Provider dikonfigurasi lewat UI Authentik di bagian Cara Pemakaian, dan itu jalur yang sepenuhnya valid. Blueprint adalah alternatif otomatis: [`blueprint.yaml`](blueprint.yaml) membuat grup `demo-users`, provider Proxy IT-Tools, provider OAuth2 Poznote (confidential, *redirect URI* `oidc_callback.php`, scope eksplisit, *signing key* RSA), kedua *application*-nya, dan `authentik_host` embedded outpost ke URL publik, mencegah bug "outpost menunjuk localhost" sejak awal.

**Mengapa opt-in:** blueprint memakai `state: present`. Setiap kali diterapkan ulang, ia **menimpa** field provider (external host, scope, signing key) dengan nilai dari file. Bila Anda mengubah provider lewat UI, blueprint aktif akan terus mengembalikannya. Karena itu mount-nya **tidak ada** di `docker-compose.override.yml`; ia hanya diaktifkan `setup.sh`, yang menyalin `docker-compose.blueprint.yml` dan menambahkannya ke `COMPOSE_FILE` di `.env`. Deployment manual tidak menambahkannya dan bebas dari blueprint. (Aktivasi manual: salin kedua file itu ke `/opt/authentik`, lalu tambahkan `:docker-compose.blueprint.yml` di `COMPOSE_FILE` dan `docker compose up -d server worker`.)

Mount-nya ke `/blueprints/custom/demo.yaml` pada `server`+`worker`, subdirektori *custom*, *packaged defaults* Authentik tidak tertimpa. Sesuai dokumentasi resmi, *worker* melakukan *auto-discovery*: file baru otomatis dibuat *instance*-nya dan diterapkan; perubahan file memicu *apply* ulang. Urutan dependensi (flow *implicit-consent* + *scope mappings* sistem) dijamin lewat entri `metaapplyblueprint` karena *discovery order* tidak dijamin. *Signing key* dipilih lewat lookup `!Find` ke key pair internal bawaan Authentik (`goauthentik.io/crypto/jwt-managed`, RSA), blueprint tidak bisa membuat key pair RSA sendiri, dan Poznote hanya menerima JWKS `kty=RSA`. Provider OAuth2 Poznote sengaja **tidak** di-*attach* ke outpost (outpost proxy menolak non-ProxyProvider), sehingga tidak muncul di daftar aplikasi outpost. Blueprint dibuat dari pengalaman deployment nyata, bukan contoh kosong.

#### LXC (Proxmox helper script)
<!-- TODO: opsional, bandingkan dengan instalasi Docker (lebih ringan dan mudah di-snapshot, tetapi kurang portabel) -->



# Cara Pemakaian
[`^ kembali ke atas ^`](#)

1. **Login dan portal pengguna**: tampilan yang dilihat pengguna biasa setelah login <!-- TODO: screenshot -->

2. **Pengguna dan grup**: buat beberapa pengguna uji dengan peran berbeda, misalnya grup `demo-users` (berhak) dan satu pengguna di luar grup itu (tidak berhak). <!-- TODO: screenshot -->

3. **Melindungi IT-Tools dengan forward auth**
    1. Di Authentik: **Applications → Create with Provider**. Nama `IT-Tools`.
    2. Pilih tipe provider **Proxy**, mode **Forward auth (single application)**, dan isi *External host* dengan `https://<TOOLS_PUBLIC_HOST>`.
    3. Pastikan aplikasi ini ditambahkan ke **authentik Embedded Outpost**.
    4. Buka `https://<TOOLS_PUBLIC_HOST>`: browser dialihkan ke halaman login Authentik; setelah login, IT-Tools tampil. Tanpa sesi, permintaan wajib melewati pemeriksaan login outpost dulu (keamanan *fail closed*).

    <!-- TODO: screenshot; sebutkan bahwa IT-Tools sendiri tidak punya fitur login -->

    > **Perbaiki Embedded Outpost setelah bootstrap**: karena akun admin pertama dibuat lewat `http://localhost:9000` (SSH loopback), Authentik dapat menganggap URL utamanya localhost. Buka **Applications → Outposts → authentik Embedded Outpost → Edit** dan set `authentik_host` ke URL browser penuh: `https://<AUTH_PUBLIC_HOST>/`. Biarkan `authentik_host_browser` kosong (URL browser sama, bukan issuer kedua). Jangan pernah menghubungkan hostname publik langsung ke `it-tools:80`. (Bila Anda memakai [blueprint](#blueprint-opsi-ketiga-opt-in-konfigurasi-sebagai-kode), langkah ini sudah otomatis, cukup verifikasi.)

4. **Login Poznote lewat OIDC**
    1. Di Authentik: **Applications → Create with Provider**. Nama `Poznote`, tipe provider **OAuth2/OpenID**, *client type* **Confidential**. Pilih *application slug* `poznote` (dipakai di URL issuer, jadi harus konsisten).
    2. *Redirect URI* (strict): `https://<POZNOTE_PUBLIC_HOST>/oidc_callback.php`. Scope: `openid`, `profile`, `email`. **Signing Key**: pilih *key pair* yang tercantum di UI (mis. `authentik Self-signed Certificate`, dibuat otomatis saat instalasi; atau *Generate new key pair* di **Customization → Certificates**). Poznote hanya menerima JWKS `kty=RSA`; tanpa signing key Authentik memakai HS256 dan token ditolak. (Key internal `authentik Internal JWT Certificate` memang tidak muncul di daftar UI, disembunyikan dari listing.)

       > Callback Poznote memakai file `oidc_callback.php` di root, bukan `/oidc/callback`. Jika provider Poznote sudah ada dari setup lama, **edit** provider itu daripada menduplikasinya.
    3. Buka `https://<POZNOTE_PUBLIC_HOST>`; bila kredensial bawaan belum diganti pada langkah instalasi, login sebagai `admin_change_me` / `admin` dan ganti **username dan password** administrator sekarang.
    4. Di Poznote: **Settings > Admin Tools > OIDC / SSO**, aktifkan OIDC dengan isian berikut:

        | Field | Isi |
        |---|---|
        | Enabled | ✓ |
        | Issuer | `https://<AUTH_PUBLIC_HOST>/application/o/poznote/` |
        | Provider Name | `Authentik` |
        | Scopes | `openid profile email` |
        | Auto-create Users | ✓ |

        Biarkan *Discovery URL* kosong: Poznote menurunkannya dengan menambahkan `/.well-known/openid-configuration` ke *Issuer URL*. Poznote membangun callback/logout dari nama host permintaan, jadi pastikan hostnya sesuai Redirect URI yang terdaftar. Jangan pakai issuer ber-HTTP/internal; jangan ubah login lokal Poznote menjadi SSO-only.

        Pada **Opsi B**, container Poznote harus bisa menjangkau issuer dan JWKS publik tersebut lewat koneksi keluar (Cloudflare). Jangan pakai issuer container-name/HTTP internal, split DNS, atau bypass TLS.
    5. Masukkan **Client ID** dan **Client Secret** dari provider Authentik ke `/opt/authentik/.env` (interpolasi Compose, bukan secret literal di YAML):
       ```
       POZNOTE_OIDC_CLIENT_ID=<client-id>
       POZNOTE_OIDC_CLIENT_SECRET=<client-secret>
       ```
       Kedua variabel ini sudah di-wire ke environment container Poznote (`docker-compose.override.yml`); nilai yang Anda salin harus **persis sama** dengan yang tampil di halaman provider Authentik.
    6. Buat ulang hanya kontainer Poznote (`down` seluruh stack tidak diperlukan):
       ```
       $ sudo docker compose up -d poznote
       ```
    7. Keluar dari Poznote. Halaman login sekarang menampilkan tombol "Continue with Authentik"; pengguna baru otomatis mendapatkan akun Poznote sendiri.

    > **Pengguna blueprint**: bila stack dijalankan lewat `setup.sh` (atau overlay blueprint aktif), langkah 1–2 dan 5 sudah otomatis. Provider, scope, signing key, dan kredensial dibuat blueprint dari `.env`; cukup verifikasi di **Applications**, lalu lanjut ke langkah 3.

5. **Pendaftaran MFA**: TOTP dan/atau passkey <!-- TODO -->

6. **Kebijakan akses**: hubungkan grup `demo-users` ke aplikasi (*Application → Policy / Group / User Bindings*), lalu coba login sebagai pengguna di luar grup dan tunjukkan bahwa akses ditolak. Kebijakan lain: pembatasan berdasarkan IP atau waktu. <!-- TODO -->

7. **Flow kustom**: pendaftaran atau pemulihan kata sandi <!-- TODO -->

8. **Audit log (Events)**: login berhasil, percobaan gagal, dan penolakan kebijakan <!-- TODO -->

#### Alur Demo
1. Buka `https://<TOOLS_PUBLIC_HOST>` → dialihkan ke login Authentik.
2. Login dengan MFA → IT-Tools tampil (tanpa login tambahan).
3. Buka `https://<POZNOTE_PUBLIC_HOST>` → klik login dengan Authentik → masuk otomatis (SSO) dengan akun Poznote milik sendiri.
4. Login sebagai pengguna di luar grup → akses ditolak oleh *policy*.
5. Tunjukkan kejadian tersebut di *audit log*.

Tidak perlu entri *hosts file* di komputer browser dan tidak ada peringatan sertifikat: Opsi A memakai sertifikat publik ACME Caddy, Opsi B menyerahkan DNS dan TLS ke edge Cloudflare.

#### Pemecahan Masalah (dari pengalaman deploy nyata)

Gejala, penyebab, dan solusi yang benar-benar terjadi saat deployment Opsi B:

| Gejala | Penyebab | Solusi |
|---|---|---|
| Login IT-Tools dialihkan ke `localhost` → `ERR_CONNECTION_REFUSED` | Embedded Outpost mengira host Authentik = `http://localhost:9000` karena bootstrap lewat SSH loopback | **Applications → Outposts → authentik Embedded Outpost → Edit**: set `authentik_host` ke `https://<AUTH_PUBLIC_HOST>/` (URL penuh, trailing slash). Jangan set `authentik_host_browser`. Lihat blok "Perbaiki Embedded Outpost" di atas, ini WAJIB dicek setelah bootstrap lokal, jangan dianggap opsional |
| Setelah login, IT-Tools menampilkan halaman "Not Found / Powered by authentik" | *Kemungkinan* (belum terverifikasi dari log): cookie sesi proxy dari percobaan saat outpost masih salah, atau *External host* provider tidak sama persis dengan hostname publik (mis. `tools.` vs `ittools.`) | Kumpulkan bukti dulu: URL lengkap di address bar browser + `sudo docker compose logs caddy server --tail=50`, dan pastikan route Cloudflare untuk host ini menunjuk `caddy:80` (bukan `server:9000`). Kandidat solusi: jendela *incognito* (cookie lama), samakan *External host* provider dengan `https://<TOOLS_PUBLIC_HOST>` persis, pastikan ketiganya identik: hostname route Cloudflare, `TOOLS_PUBLIC_HOST` di `.env`, *External host* |
| IT-Tools `502 Bad Gateway` | Kontainer `it-tools` tidak berjalan (versi `setup.sh` lama tidak memulainya; `--profile tunnel up -d cloudflared` hanya menarik dependensinya, caddy) | `sudo docker compose up -d it-tools` (atau `up -d` penuh). `setup.sh` versi baru sudah ikut menjalankannya saat bootstrap |
| Pengaturan Poznote (OIDC, kata sandi) hilang setiap *recreate* kontainer | *Mount* volume salah target: Poznote menyimpan data di `/var/www/html/data`, bukan `/app/data`; DB di-*recreate* kosong setiap kontainer dibuat ulang | Pastikan memakai `docker-compose.override.yml` versi baru (`poznote_data:/var/www/html/data`). Bila data lama tertimpa: hentikan konektor dan poznote, salin `/var/www/html/data` dari kontainer lama **sebelum** *recreate*, pulihkan ke volume, baru jalankan ulang |
| Tombol login OIDC Poznote tidak muncul | `oidc_is_enabled()` Poznote hanya cek: toggle Enabled, Issuer terisi, dan `POZNOTE_OIDC_CLIENT_ID` terisi di environment, bukan koneksi jaringan | Tambahkan Client ID/Secret ke `.env` lalu `sudo docker compose up -d poznote`; pastikan toggle Enabled tersimpan |
| Lupa kata sandi admin Poznote | Hash password per-profil disimpan di `master.db` | Ikuti [Lost administrator password di TROUBLESHOOTING.md upstream](https://github.com/timothepoznanski/poznote/blob/main/docs/TROUBLESHOOTING.md): set `users.password_hash = NULL` dan `password_login_disabled = 0` untuk admin tsb (henti ingress dulu), login dengan kata sandi default, **langsung ganti** |
| HTTP publik tidak dialihkan / query string hilang setelah redirect | Rule Single Redirect belum dibuat, atau *Preserve query string* belum diaktifkan (default: nonaktif!) | Buat rule per host `http://<host>/*` → `https://<host>/${1}`, 301, dan **aktifkan** *Preserve query string* secara eksplisit sebelum Deploy |
| `setup.sh` → `Permission denied` | File tidak *executable* (bit eksekusi hilang saat diunduh tanpa git) | `chmod +x setup.sh`. Versi repo sekarang sudah menyimpan bit executable di git |
| Tidak bisa SSH ke VM VirtualBox (NAT default) | VirtualBox mode NAT tidak meneruskan port ke host; VM tidak punya IP yang bisa dijangkau host secara langsung | VirtualBox → VM → Settings → Network → Port Forwarding: isi **Host IP `127.0.0.1`**, Host Port `2222`, Guest Port `22`. Lalu dari host: `ssh -p 2222 user@127.0.0.1` dan bootstrap `ssh -p 2222 -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 user@127.0.0.1`. Jangan biarkan Host IP kosong, itu mengekspos SSH ke semua antarmuka host |
| IT-Tools tidak bisa diakses lewat `localhost` seperti Authentik/Poznote | Sesuai desain: IT-Tools tidak punya port host sama sekali (tidak ada yang perlu di-*bootstrap*), hanya bisa lewat Caddy di balik gerbang forward-auth | Akses selalu lewat `https://<TOOLS_PUBLIC_HOST>`; buat provider Proxy dulu bila belum |

Aturan umum yang berulang: **hostname harus identik di tiga tempat**, route Cloudflare, `*_PUBLIC_HOST` di `.env`, dan pengaturan provider Authentik. Beda satu huruf = aliran login putus di tengah.




# Pembahasan
[`^ kembali ke atas ^`](#)

#### Kelebihan
- Antarmuka modern
- *Flow* dan kebijakan yang fleksibel
- Mendukung OIDC, SAML, LDAP, dan proxy auth
- Mendukung blueprint (konfigurasi sebagai kode)
- Aktif dikembangkan

<!-- TODO: tambahkan hasil pengalaman sendiri -->

#### Kekurangan
- Lebih berat daripada Authelia
- Banyak konsep yang harus dipelajari
- Dokumentasi untuk kasus khusus (*edge case*) kurang lengkap

<!-- TODO: tambahkan hasil pengalaman sendiri -->

#### Aspek Keamanan
<!-- TODO: bagian anggota kelompok keamanan
- perlindungan brute force
- opsi MFA
- audit log
- hardening: antarmuka admin yang terbuka, penyimpanan secret, pembaruan
- hasil pengujian (nmap, percobaan login gagal berulang)
-->

#### Perbandingan dengan Aplikasi Sejenis



| Aspek | Authentik | Auth0 |
|---|---|---|
| Model deployment | Self-hosted | Cloud-hosted SaaS, dikelola vendor |
| Model harga | Edisi open-source gratis; biaya infrastruktur dan operasional sendiri | Free tier hingga 25.000 MAU (Monthly Active Users); paket berbayar berdasarkan MAU dan fitur |
| Kontrol / kustomisasi | Kontrol penuh atas infrastruktur dan data; flow dan kebijakan fleksibel | Dashboard dan Actions untuk kustomisasi; infrastruktur dan batas platform dikelola vendor |
| Beban operasional | Mengelola server, pembaruan, backup, dan ketersediaan sendiri | Tidak mengelola server IdP; tetap perlu konfigurasi dan integrasi aplikasi |
| Ukuran / kebutuhan resource | Sedang | Tidak perlu server IdP sendiri; integrasi AD/LDAP memerlukan connector lokal |
| Antarmuka manajemen | Ada, modern | Dashboard web modern |
| Protokol | OIDC, SAML, LDAP, proxy | OIDC, SAML; integrasi AD/LDAP melalui connector, bukan penyedia LDAP untuk aplikasi |
| Kesulitan instalasi | Mudah | Tidak perlu instalasi server IdP; konfigurasi tenant dan aplikasi |
| Cocok untuk | Homelab hingga organisasi kecil yang sensitif biaya dan membutuhkan kontrol penuh | Tim yang membayar untuk layanan terkelola dan mengurangi beban operasional IdP |
| Kelebihan / kekurangan | Kontrol dan kustomisasi tinggi, tetapi tim mengelola operasi sendiri | Operasi IdP ditangani vendor; dukungan enterprise dan opsi HA tersedia pada paket tertentu. Biaya mengikuti MAU, ada ketergantungan vendor, dan kustomisasi dibatasi platform |

Keycloak tetap menjadi alternatif self-hosted matang berbasis Java untuk kebutuhan IAM enterprise.



# Referensi
[`^ kembali ke atas ^`](#)

1. [Authentik Documentation](https://docs.goauthentik.io/)
2. [Docker Engine install on Debian](https://docs.docker.com/engine/install/debian/)
3. [Docker Engine install on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
4. [Caddy Documentation](https://caddyserver.com/docs/)
5. [IT-Tools](https://github.com/CorentinTh/it-tools)
6. [Poznote Documentation](https://github.com/timothepoznanski/poznote)
7. [Auth0 Documentation](https://auth0.com/docs)
8. [Cloudflare Tunnel: Get started](https://developers.cloudflare.com/tunnel/get-started/)
9. [Cloudflare Tunnel: Run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/)
10. [Cloudflare Tunnel: Tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/tunnel-with-firewall/)
11. [Cloudflare: Redirect requests to a different hostname](https://developers.cloudflare.com/rules/url-forwarding/examples/redirect-all-different-hostname/)
12. [Authentik: Reverse proxy](https://docs.goauthentik.io/install-config/reverse-proxy/)
13. [Authentik: Embedded Outpost](https://docs.goauthentik.io/add-secure-apps/outposts/embedded/)
14. [Authentik: Caddy forward auth](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_caddy/)
15. [Docker: Merge Compose files](https://docs.docker.com/reference/compose-file/merge/)
16. [Docker: Predefined environment variables](https://docs.docker.com/compose/how-tos/environment-variables/envvars/)
<!-- TODO: tambahkan tutorial lain yang dipakai -->




<!--
CATATAN INTERNAL KELOMPOK (hapus sebelum dikumpulkan)

Pembagian tugas (5 orang):
- Kamu: instalasi, blueprint/otomatisasi, integrasi homelab
- Anggota 1 (keamanan): hardening, uji brute force dan MFA, analisis audit log
- Lainnya: perbandingan Keycloak dan Authelia, screenshot dan dokumentasi pemakaian, slide dan skrip demo

Hal yang perlu diperhatikan:
- Tugas meminta VM lokal. Menjalankan Docker di dalam LXC Proxmox butuh nesting dan bisa merepotkan; gunakan VM untuk proyek, pindah ke homelab setelahnya (opsional).
- Demo dipublikasikan lewat dua opsi: VPS dengan IP publik (Caddy + ACME), atau komputer lokal via Cloudflare Tunnel. Bootstrap admin selalu lewat SSH loopback sebelum ingress publik aktif.
- Karena belum pernah memakai SSO, kerjakan IT-Tools (forward auth) dulu, baru Poznote (OIDC).
- Demo mandiri: Caddy, IT-Tools, dan Poznote ada di compose stack yang sama sehingga tidak bergantung pada jaringan homelab.
- Pilih salah satu opsi hosting sesuai infrastruktur yang tersedia; keduanya memakai docker-compose.override.yml yang sama.
-->
