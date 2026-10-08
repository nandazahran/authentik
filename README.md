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
    1. Di Authentik: **Applications → Create with Provider**. Nama `Poznote`, tipe provider **OAuth2/OpenID**, *client type* **Confidential**.
    2. *Redirect URI* (strict): `https://poznote-demo.lab.local/oidc/callback`. Scope: `openid`, `profile`, `email`. Catat **Client ID** dan **Client Secret**.
    3. Buka `https://poznote-demo.lab.local` dan login dengan akun default:
       - Username: `admin_change_me`
       - Password: `admin`
       - Ganti password setelah login pertama.
    4. Di Poznote: **Settings > Admin Tools > OIDC / SSO**, aktifkan OIDC dengan isian berikut:

        | Field | Isi |
        |---|---|
        | Enabled | ✓ |
        | Issuer | `https://auth-demo.lab.local/application/o/<application-slug>/` |
        | Provider Name | `Authentik` |
        | Scopes | `openid profile email` |
        | Auto-create Users | ✓ |

    5. Masukkan **Client ID** dan **Client Secret** ke environment variables Poznote di `docker-compose.override.yml`:
       ```yaml
       poznote:
         environment:
           POZNOTE_OIDC_CLIENT_ID: "<client-id>"
           POZNOTE_OIDC_CLIENT_SECRET: "<client-secret>"
       ```
    6. Restart kontainer: `docker compose down && docker compose up -d`
    7. Keluar dari Poznote. Halaman login sekarang menampilkan tombol "Continue with Authentik"; pengguna baru otomatis mendapatkan akun Poznote sendiri.

5. **Pendaftaran MFA**: TOTP dan/atau passkey <!-- TODO -->

6. **Kebijakan akses**: hubungkan grup `demo-users` ke aplikasi (*Application → Policy / Group / User Bindings*), lalu coba login sebagai pengguna di luar grup dan tunjukkan bahwa akses ditolak. Kebijakan lain: pembatasan berdasarkan IP atau waktu. <!-- TODO -->

7. **Flow kustom**: pendaftaran atau pemulihan kata sandi <!-- TODO -->

8. **Audit log (Events)**: login berhasil, percobaan gagal, dan penolakan kebijakan <!-- TODO -->

#### Alur Demo
1. Buka `tools-demo.lab.local` → dialihkan ke login Authentik.
2. Login dengan MFA → IT-Tools tampil (tanpa login tambahan).
3. Buka `poznote-demo.lab.local` → klik login dengan Authentik → masuk otomatis (SSO) dengan akun Poznote milik sendiri.
4. Login sebagai pengguna di luar grup → akses ditolak oleh *policy*.
5. Tunjukkan kejadian tersebut di *audit log*.



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
