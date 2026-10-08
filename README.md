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
- Menyediakan **HTTPS** dengan nama host yang rapi (`auth-demo.lab.local`, dll.). Sertifikat dibuat otomatis dari CA lokal milik Caddy (`tls internal`).
- Menjadi **penjaga pintu** untuk aplikasi yang tidak punya login sendiri (*forward auth*, lihat di bawah).
- Membuat hanya satu titik masuk (port 80/443) yang terbuka ke jaringan, sehingga port internal aplikasi tidak perlu diekspos.

Caddy **tidak wajib** untuk menjalankan Authentik (Authentik sudah bisa diakses lewat port 9000), tetapi diperlukan agar demo HTTPS dan *forward auth* berjalan.

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
- Debian 12+ / Ubuntu 22.04+ (VM)
- RAM minimal 2 GB (disarankan 3-4 GB jika demo Caddy + IT-Tools + Poznote ikut dijalankan)
- CPU 2 core
- Disk 20 GB
- Docker Engine dan Docker Compose plugin



#### Proses Instalasi :
1. Buat VM (Debian) dan login menggunakan SSH.
    ```
    $ ssh user@<ip-vm>
    ```

2. Instal Docker dari repositori resmi Docker (bukan `docker.io` bawaan distro).
    ```
    $ sudo apt-get update
    $ sudo apt-get install -y ca-certificates curl gnupg
    $ sudo install -m 0755 -d /etc/apt/keyrings
    $ sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    $ sudo chmod a+r /etc/apt/keyrings/docker.asc
    $ echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    $ sudo apt-get update
    $ sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ```

3. Unduh `docker-compose.yml` resmi Authentik.
    ```
    $ sudo mkdir -p /opt/authentik && cd /opt/authentik
    $ sudo curl -fsSL -o docker-compose.yml https://docs.goauthentik.io/compose.yml
    ```

4. Buat file `.env` berisi *secret* acak (`openssl rand`).
    ```
    $ echo "PG_PASS=$(openssl rand -base64 36 | tr -d '\n')" | sudo tee .env
    $ echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" | sudo tee -a .env
    $ sudo chmod 600 .env
    ```

5. Tambahkan Caddy dan aplikasi demo: salin [`docker-compose.override.yml`](docker-compose.override.yml) dan [`Caddyfile`](Caddyfile) ke `/opt/authentik`. Docker Compose menggabungkan file override secara otomatis, sehingga file resmi tidak perlu diubah. (Lewati langkah ini jika hanya ingin Authentik saja.)
    ```
    $ sudo cp docker-compose.override.yml Caddyfile /opt/authentik/
    ```

6. Jalankan.
    ```
    $ sudo docker compose pull
    $ sudo docker compose up -d
    ```

7. Pada komputer yang menjalankan browser, tambahkan nama host ke *hosts file* (`/etc/hosts` di Linux/macOS, `C:\Windows\System32\drivers\etc\hosts` di Windows):
    ```
    <ip-vm>  auth-demo.lab.local tools-demo.lab.local poznote-demo.lab.local
    ```

8. Buka `https://auth-demo.lab.local/if/flow/initial-setup/` (atau `http://<ip-vm>:9000/if/flow/initial-setup/` tanpa Caddy) dan buat akun admin. Browser akan memperingatkan soal sertifikat karena CA lokal Caddy belum dipercaya; untuk demo peringatan ini dapat dilewati.

9. Verifikasi kontainer berjalan.
    ```
    $ sudo docker compose ps
    ```

<!-- TODO: screenshot setiap langkah, seperti pada contoh laporan -->

#### Catatan Keamanan Instalasi
- Hanya Caddy (port 80/443) yang seharusnya menjadi titik masuk; jangan biarkan port bawaan aplikasi terbuka ke jaringan luas.
- Simpan `.env` dengan izin `600` dan jangan pernah dimasukkan ke git (tambahkan ke `.gitignore`).
- Port yang dipublikasikan Docker dapat melewati aturan `ufw`; verifikasi dengan `nmap` dari mesin lain.
- Buat kata sandi admin sendiri saat *initial setup*, jangan ditulis di dalam script.
- Tetapkan versi *image* (jangan `latest`) untuk penggunaan di luar demo.

<!-- TODO: hasil pengujian nmap -->



#### Instalasi Mode Publik (Cloudflare Tunnel)

Mode LAN di atas mempublikasikan port 80/443 ke jaringan lokal. Mode publik membuat demo dapat diakses dari internet **tanpa port forwarding di router**: `cloudflared` di VM melakukan koneksi *outbound* ke Cloudflare, HTTPS dihentikan di edge Cloudflare, dan Caddy dihubungi lewat jaringan internal Compose. Syarat: satu domain yang dikelola akun Cloudflare Anda, dan Docker Compose plugin >= 2.24.4 (diperlukan tag `!override`/`!reset` di `docker-compose.tunnel.yml`).

> **Jangan** jalankan `setup.sh --demo` untuk instalasi tunnel baru — script itu mode LAN dan sempat membuka port web ke semua antarmuka. Mode LAN tetap didukung sebagai mode terpisah.

Nama host contoh di bawah (`auth.example.com`, `tools.example.com`, `poznote.example.com`) hanyalah contoh, bukan nilai harfiah. Gunakan tiga subdomain satu tingkat di bawah domain Cloudflare Anda — mis. `auth.<domain>`, `tools.<domain>`, `poznote.<domain>` — agar tercakup *edge certificate* standar; ketiganya harus FQDN yang berbeda dan belum dipakai record lain. Bila sebuah label sudah dipakai DNS milik layanan lain, jangan ditimpa: pilih label lain (mis. tambah `-demo`) dan gunakan nilai yang sama secara konsisten di `.env`, route Cloudflare, dan pengaturan provider.

1. Gunakan VM Debian/Ubuntu yang sudah disediakan dengan akses SSH. Instal Docker dari repositori resmi (langkah 2 di atas), lalu unduh compose resmi Authentik ke `/opt/authentik`:
    ```
    $ sudo mkdir -p /opt/authentik
    $ sudo curl -fsSL -o /opt/authentik/docker-compose.yml https://docs.goauthentik.io/compose.yml
    ```

2. Dari **direktori repo** (tempat file konfigurasi ini berada), salin konfigurasi ke `/opt/authentik`, lalu buat dan isi `.env`:
    ```
    $ sudo cp docker-compose.override.yml docker-compose.tunnel.yml Caddyfile Caddyfile.tunnel /opt/authentik/
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
    `COMPOSE_FILE` membuat overlay tunnel selalu aktif untuk setiap perintah `docker compose` dari direktori ini; jangan simpan `COMPOSE_PROFILES=tunnel` (konektor sengaja tidak ikut `up -d` biasa). Buat juga file token konektor (kosong dulu) milik root:
    ```
    $ sudo touch cloudflared.env && sudo chmod 600 cloudflared.env
    $ sudo chmod 600 .env
    ```

3. Validasi dan jalankan stack (konektor belum dibuat karena profile `tunnel` tidak aktif):
    ```
    $ sudo docker compose config --quiet
    $ sudo docker compose pull
    $ sudo docker compose up -d
    ```
    Jangan pernah mencetak `docker compose config` tanpa `--quiet` di mesin berisi secret asli. Konfirmasi Authentik sehat sebelum lanjut:
    ```
    $ curl -fsS http://127.0.0.1:9000/-/health/live/
    ```

4. Dari komputer yang menjalankan browser, buka SSH *port forward* (halaman ini hanya lewat SSH, tidak dipublikasikan ke LAN):
    ```
    $ ssh -N -L 9000:127.0.0.1:9000 -L 8040:127.0.0.1:8040 user@<ip-vm>
    ```
    - Buka `http://localhost:9000/if/flow/initial-setup/` dan buat kata sandi admin Authentik yang kuat.
    - Buka `http://localhost:8040`, login Poznote sebagai `admin_change_me` / `admin`, lalu ganti **username dan password** administratornya di UI Poznote. Pastikan kredensial lama tidak bisa login lagi.

    **Aktivasi tunnel dilarang sebelum kedua akun di atas selesai diganti.** Panduan MFA di bagian Konfigurasi tetap berlaku.

5. Di dashboard Cloudflare (Zero Trust > Networks > Tunnels) buat satu tunnel *remotely managed* bernama `authentik-demo`. Simpan token tunnel sebagai `TUNNEL_TOKEN=<token-asli>` di `/opt/authentik/cloudflared.env` **menggunakan editor** — bukan argumen command-line atau assignment shell yang masuk riwayat shell:
    ```
    $ sudo nano /opt/authentik/cloudflared.env
    ```
    Buat tiga *public hostname* di tunnel tersebut, masing-masing satu nama host pilihan Anda, *Service type* **HTTP** dengan URL `caddy:80`, tanpa path. Biarkan *HTTP Host Header override* kosong agar Host publik asli sampai ke Caddy; **jangan** aktifkan *No TLS Verify* (origin memang HTTP). Biarkan dashboard membuat CNAME untuk tiap hostname.

6. Pastikan HTTP publik dialihkan ke HTTPS di edge. Untuk tiap hostname, buat **Single Redirect** rule: *Request URL* wildcard `http://<host>/*`, *Target URL* `https://<host>/${1}`, status `301`, *Preserve query string* aktif. Cakupan rule hanya host-host ini; jangan mengubah kebijakan HTTPS layanan lain di zone. Tunggu *edge certificate* tiap hostname aktif. Tidak ada layer login Cloudflare Access tambahan — autentikasi demo tetap di Authentik/Poznote.

7. Aktifkan konektor setelah kedua akun admin diganti:
    ```
    $ sudo docker compose --profile tunnel pull cloudflared
    $ sudo docker compose --profile tunnel up -d cloudflared
    ```
    Pantau status **Healthy** dan log konektor di dashboard sebelum mengonfigurasi integrasi publik di bagian Cara Pemakaian. IT-Tools tetap tertutup (*fails closed*) sampai provider-nya dibuat.

8. Jaringan: tetap nonaktifkan *port forwarding* 80/443 di router. Firewall VM cukup mengizinkan *outbound* DNS, HTTPS (*pull image*, discovery OIDC Poznote), dan TCP/UDP 7844 untuk Cloudflare Tunnel; pertahankan SSH dari jaringan administrasi; **jangan** buka inbound 80/443/9000/9443/8040. Isolasi ingress mengandalkan binding Docker yang dihapus/di-loopback (`docker-compose.tunnel.yml`), bukan `ufw` saja.

    Migrasi dari deployment LAN yang sudah berjalan: hentikan konektor dulu bila ada, pertahankan secret `.env` dan *named volume* (`down -v` dilarang), salin `docker-compose.tunnel.yml` + `Caddyfile.tunnel`, set `COMPOSE_FILE`, lalu `sudo docker compose up -d` untuk mengganti binding. Selesaikan penggantian akun admin yang belum diganti lewat SSH loopback sebelum mengaktifkan kembali konektor.

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
Seluruh konfigurasi Caddy ada di [`Caddyfile`](Caddyfile). Setiap blok mewakili satu nama host:

| Host | Diteruskan ke | Fungsi |
|---|---|---|
| `auth-demo.lab.local` | `server:9000` | Antarmuka Authentik |
| `tools-demo.lab.local` | `it-tools:80` | IT-Tools, dilindungi *forward auth* |
| `poznote-demo.lab.local` | `poznote:80` | Poznote, login lewat OIDC |

Pada blok `tools-demo.lab.local`, direktif `forward_auth` membuat Caddy bertanya ke Authentik apakah pengguna sudah login sebelum permintaan diteruskan ke IT-Tools, dan menyalin header identitas (`X-Authentik-Username`, dll.) ke aplikasi.


<!-- TODO: opsional, pasang root CA Caddy di browser agar tidak ada peringatan sertifikat -->



# Otomatisasi
[`^ kembali ke atas ^`](#)

Dengan otomatisasi, seluruh instalasi dan konfigurasi dapat direproduksi.

#### Cara 1: Shell script
Jalankan [setup.sh](setup.sh) pada VM Debian/Ubuntu baru (dengan `Caddyfile` dan `docker-compose.override.yml` di folder yang sama):
```
$ sudo ./setup.sh --harden --demo
```
- `--harden`: mengatur `ufw`, `unattended-upgrades`, dan `fail2ban`
- `--demo`: ikut menjalankan Caddy, IT-Tools, dan Poznote

Script melakukan: pengecekan awal, instalasi Docker dari repo resmi, *hardening* dasar (opsional), *deploy* Authentik (dan aplikasi demo, opsional), lalu menunggu sampai layanan sehat. Script bersifat *idempotent*: dijalankan ulang tidak akan mengganti *secret* atau file konfigurasi yang sudah ada.

#### Cara 2: Blueprint (konfigurasi sebagai kode)
Blueprint adalah file YAML yang membuat pengguna, grup, dan aplikasi secara otomatis, sehingga seluruh lingkungan demo dapat dibuat ulang dengan satu perintah.

<!-- TODO: contoh blueprint YAML untuk grup, aplikasi IT-Tools, dan aplikasi Poznote -->

#### Cara 3: LXC (Proxmox helper script)
<!-- TODO: opsional, bandingkan dengan instalasi Docker (lebih ringan dan mudah di-snapshot, tetapi kurang portabel) -->



# Cara Pemakaian
[`^ kembali ke atas ^`](#)

1. **Login dan portal pengguna**: tampilan yang dilihat pengguna biasa setelah login <!-- TODO: screenshot -->

2. **Pengguna dan grup**: buat beberapa pengguna uji dengan peran berbeda, misalnya grup `demo-users` (berhak) dan satu pengguna di luar grup itu (tidak berhak). <!-- TODO: screenshot -->

3. **Melindungi IT-Tools dengan forward auth**
    1. Di Authentik: **Applications → Create with Provider**. Nama `IT-Tools`.
    2. Pilih tipe provider **Proxy**, mode **Forward auth (single application)**, dan isi *External host* dengan `https://tools-demo.lab.local`.
    3. Pastikan aplikasi ini ditambahkan ke **authentik Embedded Outpost**.
    4. Buka `https://tools-demo.lab.local`: browser dialihkan ke halaman login Authentik; setelah login, IT-Tools tampil.

    <!-- TODO: screenshot; sebutkan bahwa IT-Tools sendiri tidak punya fitur login -->

4. **Login Poznote lewat OIDC**
    1. Di Authentik: **Applications → Create with Provider**. Nama `Poznote`, tipe provider **OAuth2/OpenID**, *client type* **Confidential**. Pilih *application slug* `poznote` (dipakai di URL issuer, jadi harus konsisten).
    2. *Redirect URI* (strict): `https://poznote-demo.lab.local/oidc_callback.php`. Scope: `openid`, `profile`, `email`. Catat **Client ID** dan **Client Secret**.

       > Callback Poznote memakai file `oidc_callback.php` di root — bukan `/oidc/callback`. Jika provider Poznote sudah ada dari setup lama, **edit** provider itu daripada menduplikasinya.
    3. Buka `https://poznote-demo.lab.local` dan login dengan akun default:
       - Username: `admin_change_me`
       - Password: `admin`
       - Ganti **username dan password** administrator sebelum paparan apa pun terjadi.
    4. Di Poznote: **Settings > Admin Tools > OIDC / SSO**, aktifkan OIDC dengan isian berikut:

        | Field | Isi |
        |---|---|
        | Enabled | ✓ |
        | Issuer | `https://auth-demo.lab.local/application/o/poznote/` |
        | Provider Name | `Authentik` |
        | Scopes | `openid profile email` |
        | Auto-create Users | ✓ |

        Biarkan *Discovery URL* kosong: Poznote menurunkannya dengan menambahkan `/.well-known/openid-configuration` ke *Issuer URL*. Poznote membangun callback/logout dari nama host permintaan, jadi pastikan hostnya sesuai Redirect URI yang terdaftar. Jangan pakai issuer ber-HTTP/internal; jangan ubah login lokal Poznote menjadi SSO-only.
    5. Masukkan **Client ID** dan **Client Secret** ke `/opt/authentik/.env` (interpolasi Compose, bukan secret literal di YAML):
       ```
       POZNOTE_OIDC_CLIENT_ID=<client-id>
       POZNOTE_OIDC_CLIENT_SECRET=<client-secret>
       ```
       Kedua variabel ini sudah di-wire ke environment container Poznote (di `docker-compose.override.yml` untuk mode LAN, di `docker-compose.tunnel.yml` untuk mode tunnel).
    6. Buat ulang hanya kontainer Poznote — `down` seluruh stack tidak diperlukan:
       ```
       $ sudo docker compose up -d poznote
       ```
    7. Keluar dari Poznote. Halaman login sekarang menampilkan tombol "Continue with Authentik"; pengguna baru otomatis mendapatkan akun Poznote sendiri.


    #### Untuk mode tunnel (publik)

    Nilai host publik harus sama di environment Caddy (`.env`), route Cloudflare, provider, dan pengaturan Poznote.

    - **Embedded Outpost**: karena bootstrap lokal tadi memakai `http://localhost:9000`, Authentik mengira URL utamanya localhost. Buka **Applications → Outposts → authentik Embedded Outpost → Edit**, set `authentik_host` ke URL browser penuh: `https://<AUTH_PUBLIC_HOST>/`. Biarkan `authentik_host_browser` kosong (URL browser sama, bukan issuer kedua).
    - **IT-Tools**: provider **Proxy** mode **Forward auth (single application)**, *External host* `https://<TOOLS_PUBLIC_HOST>`; tambahkan aplikasi ke embedded outpost dan ikat kebijakan/grup `demo-users` seperti pada mode LAN. Jangan pernah menghubungkan hostname Cloudflare langsung ke `it-tools:80`. Tanpa sesi, `https://<TOOLS_PUBLIC_HOST>/` harus melalui pemeriksaan login outpost dulu (keamanan *fail closed*).
    - **Poznote**: provider **OAuth2/OpenID**, Confidential client, *Redirect URI* (strict) `https://<POZNOTE_PUBLIC_HOST>/oidc_callback.php`, scope `openid profile email`. Jika provider sudah ada, edit; gunakan slug yang sama secara konsisten.
    - Di Poznote **Settings > Admin Tools > OIDC / SSO**: Enabled, Issuer `https://<AUTH_PUBLIC_HOST>/application/o/poznote/`, Provider Name `Authentik`, Scopes `openid profile email`, Auto-create Users aktif; biarkan Discovery URL kosong. Container Poznote harus bisa menjangkau issuer dan JWKS publik tersebut (koneksi keluar lewat tunnel) — jangan pakai issuer container-name/HTTP, split DNS, atau bypass TLS.
    - Simpan **Client ID/Secret** ke `/opt/authentik/.env` lalu buat ulang hanya Poznote: `sudo docker compose up -d poznote`.

5. **Pendaftaran MFA**: TOTP dan/atau passkey <!-- TODO -->

6. **Kebijakan akses**: hubungkan grup `demo-users` ke aplikasi (*Application → Policy / Group / User Bindings*), lalu coba login sebagai pengguna di luar grup dan tunjukkan bahwa akses ditolak. Kebijakan lain: pembatasan berdasarkan IP atau waktu. <!-- TODO -->

7. **Flow kustom**: pendaftaran atau pemulihan kata sandi <!-- TODO -->

8. **Audit log (Events)**: login berhasil, percobaan gagal, dan penolakan kebijakan <!-- TODO -->

#### Alur Demo
Mode LAN memakai `tools-demo.lab.local` / `poznote-demo.lab.local`. Mode tunnel menggantinya dengan host publik: `https://<TOOLS_PUBLIC_HOST>` / `https://<POZNOTE_PUBLIC_HOST>` / `https://<AUTH_PUBLIC_HOST>`.

1. Buka host IT-Tools (`tools-demo.lab.local` atau `https://<TOOLS_PUBLIC_HOST>`) → dialihkan ke login Authentik.
2. Login dengan MFA → IT-Tools tampil (tanpa login tambahan).
3. Buka host Poznote (`poznote-demo.lab.local` atau `https://<POZNOTE_PUBLIC_HOST>`) → klik login dengan Authentik → masuk otomatis (SSO) dengan akun Poznote milik sendiri.
4. Login sebagai pengguna di luar grup → akses ditolak oleh *policy*.
5. Tunjukkan kejadian tersebut di *audit log*.

Pada mode tunnel tidak perlu entri *hosts file* di komputer browser dan tidak perlu mempercayai CA lokal Caddy: DNS dan sertifikat TLS ditangani Cloudflare.



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
3. [Caddy Documentation](https://caddyserver.com/docs/)
4. [IT-Tools](https://github.com/CorentinTh/it-tools)
5. [Poznote Documentation](https://github.com/timothepoznanski/poznote)
6. [Auth0 Documentation](https://auth0.com/docs)
7. [Cloudflare Tunnel — Get started](https://developers.cloudflare.com/tunnel/get-started/)
8. [Cloudflare Tunnel — Run parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/)
9. [Cloudflare Tunnel — Tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)
10. [Cloudflare — Redirect requests to a different hostname](https://developers.cloudflare.com/rules/url-forwarding/examples/redirect-all-different-hostname/)
11. [Authentik — Reverse proxy](https://docs.goauthentik.io/install-config/reverse-proxy/)
12. [Authentik — Embedded Outpost](https://docs.goauthentik.io/add-secure-apps/outposts/embedded/)
13. [Authentik — Caddy forward auth](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_caddy/)
14. [Docker — Merge Compose files](https://docs.docker.com/reference/compose-file/merge/)
15. [Docker — Predefined environment variables](https://docs.docker.com/compose/how-tos/environment-variables/envvars/)
<!-- TODO: tambahkan tutorial lain yang dipakai -->




<!--
CATATAN INTERNAL KELOMPOK (hapus sebelum dikumpulkan)

Pembagian tugas (5 orang):
- Kamu: instalasi, blueprint/otomatisasi, integrasi homelab
- Anggota 1 (keamanan): hardening, uji brute force dan MFA, analisis audit log
- Lainnya: perbandingan Keycloak dan Authelia, screenshot dan dokumentasi pemakaian, slide dan skrip demo

Hal yang perlu diperhatikan:
- Tugas meminta VM lokal. Menjalankan Docker di dalam LXC Proxmox butuh nesting dan bisa merepotkan; gunakan VM untuk proyek, pindah ke homelab setelahnya (opsional).
- Karena belum pernah memakai SSO, kerjakan IT-Tools (forward auth) dulu, baru Poznote (OIDC).
- Demo mandiri: Caddy, IT-Tools, dan Poznote ada di compose stack yang sama sehingga tidak bergantung pada jaringan homelab.
- Pakai bridged networking pada VM supaya bisa diakses dari browser lewat IP sendiri.
- Setelah demo, hapus baris hosts file supaya tidak bentrok dengan Authentik di LXC nanti.
-->
