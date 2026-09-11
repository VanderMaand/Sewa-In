-- =====================================================================
-- CATATAN IMPLEMENTASI
-- =====================================================================
-- 1. Hak akses admin (terbatas) diterapkan di level aplikasi/API, bukan
--    di database: admin TIDAK BOLEH memanggil endpoint DELETE pada
--    tabel `aset`, dan TIDAK BOLEH mengakses `nilai_beli` /
--    `v_nilai_aset` pada endpoint yang diekspos ke role admin.
-- 2. QR code (`aset.qr_code`) di-generate saat insert aset baru,
--    lalu dirender jadi gambar QR untuk dicetak (di sisi aplikasi/API,
--    misal pakai library qrcode).
-- 3. `jadwal_maintenance.tanggal_berikutnya` dicek oleh scheduled job
--    (cron) harian untuk membuat baris baru di `notifikasi` saat
--    H-3 atau saat jatuh tempo.
-- 4. Precision NUMERIC dipakai untuk semua nilai uang agar tidak ada
--    masalah pembulatan floating point.
-- =====================================================================


-- =====================================================================
-- SKEMA DATABASE: APLIKASI MANAJEMEN ASET RUKO
-- Dialek: PostgreSQL (kompatibel MySQL dengan penyesuaian kecil)
-- =====================================================================

-- ---------------------------------------------------------------------
-- ENUM TYPES
-- ---------------------------------------------------------------------
CREATE TYPE user_role AS ENUM ('owner', 'admin', 'tenant');
CREATE TYPE unit_status AS ENUM ('kosong', 'disewa');
CREATE TYPE asset_condition AS ENUM ('baik', 'perlu_perhatian', 'rusak');
CREATE TYPE lease_status AS ENUM ('aktif', 'berakhir', 'dibatalkan');
CREATE TYPE report_status AS ENUM ('dilaporkan', 'diverifikasi', 'dijadwalkan', 'dikerjakan', 'selesai', 'ditolak');
CREATE TYPE notification_type AS ENUM ('laporan_baru', 'status_laporan', 'reminder_maintenance', 'sewa_berakhir', 'lainnya');

-- ---------------------------------------------------------------------
-- USERS
-- Menyimpan owner, admin (delegasi), dan tenant dalam satu tabel
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                VARCHAR(150) NOT NULL,
    email               VARCHAR(150) UNIQUE NOT NULL,
    phone               VARCHAR(30),
    password_hash       VARCHAR(255) NOT NULL,
    role                user_role NOT NULL,
    delegated_by_owner_id UUID REFERENCES users(id) ON DELETE SET NULL, -- diisi jika role = admin
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_role ON users(role);
CREATE INDEX idx_users_delegated_by ON users(delegated_by_owner_id);

-- ---------------------------------------------------------------------
-- RUKO
-- ---------------------------------------------------------------------
CREATE TABLE ruko (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    nama            VARCHAR(150) NOT NULL,
    alamat          TEXT NOT NULL,
    luas_m2         NUMERIC(10,2),
    foto_url        TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ruko_owner ON ruko(owner_id);

-- ---------------------------------------------------------------------
-- UNITS (satu ruko bisa dibagi beberapa unit/tenant)
-- ---------------------------------------------------------------------
CREATE TABLE units (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ruko_id         UUID NOT NULL REFERENCES ruko(id) ON DELETE CASCADE,
    nama_unit       VARCHAR(100) NOT NULL,     -- misal "Unit A", "Lantai 2"
    status          unit_status NOT NULL DEFAULT 'kosong',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (ruko_id, nama_unit)
);

CREATE INDEX idx_units_ruko ON units(ruko_id);
CREATE INDEX idx_units_status ON units(status);

-- ---------------------------------------------------------------------
-- KATEGORI ASET (menyimpan default umur ekonomis untuk depresiasi)
-- ---------------------------------------------------------------------
CREATE TABLE kategori_aset (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nama                        VARCHAR(100) NOT NULL UNIQUE, -- elektronik, furnitur, struktur, plumbing, dll
    default_umur_ekonomis_tahun NUMERIC(5,1) NOT NULL DEFAULT 5
);

-- ---------------------------------------------------------------------
-- ASET
-- ---------------------------------------------------------------------
CREATE TABLE aset (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ruko_id                 UUID NOT NULL REFERENCES ruko(id) ON DELETE CASCADE,
    unit_id                 UUID REFERENCES units(id) ON DELETE SET NULL, -- NULL = aset milik area bersama
    kategori_id             UUID NOT NULL REFERENCES kategori_aset(id),
    nama                    VARCHAR(150) NOT NULL,
    qr_code                 VARCHAR(100) UNIQUE NOT NULL,   -- kode unik yang di-generate & dicetak
    kondisi                 asset_condition NOT NULL DEFAULT 'baik',
    nilai_beli              NUMERIC(14,2) NOT NULL,
    tanggal_beli            DATE NOT NULL,
    umur_ekonomis_tahun     NUMERIC(5,1) NOT NULL,          -- override dari kategori, bisa disesuaikan per aset
    garansi_sampai          DATE,
    foto_url                TEXT,
    catatan                 TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_aset_ruko ON aset(ruko_id);
CREATE INDEX idx_aset_unit ON aset(unit_id);
CREATE INDEX idx_aset_kategori ON aset(kategori_id);
CREATE INDEX idx_aset_qr ON aset(qr_code);

-- ---------------------------------------------------------------------
-- VIEW: NILAI ASET SEKARANG (depresiasi garis lurus, dihitung on-the-fly)
-- nilai_sekarang = nilai_beli - (nilai_beli / umur_ekonomis_tahun) * tahun_berjalan
-- dibatasi minimum 0
-- ---------------------------------------------------------------------
CREATE VIEW v_nilai_aset AS
SELECT
    a.id AS aset_id,
    a.nama,
    a.nilai_beli,
    a.tanggal_beli,
    a.umur_ekonomis_tahun,
    GREATEST(
        a.nilai_beli - (a.nilai_beli / NULLIF(a.umur_ekonomis_tahun, 0))
            * EXTRACT(YEAR FROM AGE(CURRENT_DATE, a.tanggal_beli))::NUMERIC,
        0
    ) AS nilai_sekarang
FROM aset a;

-- ---------------------------------------------------------------------
-- JADWAL MAINTENANCE (interval dinamis, bisa per aset)
-- ---------------------------------------------------------------------
CREATE TABLE jadwal_maintenance (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aset_id                 UUID NOT NULL REFERENCES aset(id) ON DELETE CASCADE,
    nama_tugas              VARCHAR(150) NOT NULL,   -- misal "Servis AC"
    interval_hari           INTEGER NOT NULL,
    terakhir_dikerjakan     DATE,
    tanggal_berikutnya      DATE NOT NULL,
    aktif                   BOOLEAN NOT NULL DEFAULT true,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_jadwal_aset ON jadwal_maintenance(aset_id);
CREATE INDEX idx_jadwal_tanggal ON jadwal_maintenance(tanggal_berikutnya);

-- ---------------------------------------------------------------------
-- SEWA (leases) — termasuk dokumen kontrak
-- ---------------------------------------------------------------------
CREATE TABLE sewa (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    unit_id                 UUID NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    tenant_id               UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tanggal_mulai           DATE NOT NULL,
    tanggal_selesai         DATE NOT NULL,
    status                  lease_status NOT NULL DEFAULT 'aktif',
    dokumen_kontrak_url     TEXT,
    dokumen_identitas_url   TEXT,
    catatan                 TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (tanggal_selesai > tanggal_mulai)
);

CREATE INDEX idx_sewa_unit ON sewa(unit_id);
CREATE INDEX idx_sewa_tenant ON sewa(tenant_id);
CREATE INDEX idx_sewa_status ON sewa(status);

-- ---------------------------------------------------------------------
-- LAPORAN KERUSAKAN
-- ---------------------------------------------------------------------
CREATE TABLE laporan_kerusakan (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aset_id                 UUID NOT NULL REFERENCES aset(id) ON DELETE CASCADE,
    tenant_id               UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    deskripsi               TEXT NOT NULL,
    foto_url                TEXT,
    estimasi_biaya          NUMERIC(14,2),
    status                  report_status NOT NULL DEFAULT 'dilaporkan',
    ditangani_oleh          UUID REFERENCES users(id) ON DELETE SET NULL, -- owner/admin yang proses
    ditutup_oleh            UUID REFERENCES users(id) ON DELETE SET NULL, -- harus owner
    tanggal_lapor           TIMESTAMPTZ NOT NULL DEFAULT now(),
    tanggal_selesai         TIMESTAMPTZ,
    catatan_penanganan      TEXT
);

CREATE INDEX idx_laporan_aset ON laporan_kerusakan(aset_id);
CREATE INDEX idx_laporan_tenant ON laporan_kerusakan(tenant_id);
CREATE INDEX idx_laporan_status ON laporan_kerusakan(status);

-- ---------------------------------------------------------------------
-- NOTIFIKASI
-- ---------------------------------------------------------------------
CREATE TABLE notifikasi (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tipe            notification_type NOT NULL,
    pesan           TEXT NOT NULL,
    referensi_id    UUID,              -- id laporan/jadwal/sewa terkait (tanpa FK ketat, polymorphic)
    dibaca          BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notif_user ON notifikasi(user_id);
CREATE INDEX idx_notif_dibaca ON notifikasi(dibaca);

-- =====================================================================
-- CONTOH DATA AWAL KATEGORI (default umur ekonomis untuk depresiasi)
-- =====================================================================
INSERT INTO kategori_aset (nama, default_umur_ekonomis_tahun) VALUES
    ('Elektronik', 4),
    ('Furnitur', 8),
    ('Struktur Bangunan', 20),
    ('Plumbing', 10),
    ('Listrik & Instalasi', 10),
    ('Lainnya', 5);

