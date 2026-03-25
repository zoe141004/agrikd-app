-- ============================================================
-- AgriKD Supabase Migration: Tables + RLS Policies
-- Run this SQL in Supabase Dashboard > SQL Editor
-- Safe to re-run: uses IF NOT EXISTS and DROP POLICY IF EXISTS
-- ============================================================

-- 1. Predictions table
CREATE TABLE IF NOT EXISTS predictions (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    image_url       TEXT,
    leaf_type       TEXT NOT NULL,
    model_version   TEXT NOT NULL,
    predicted_class_index  INTEGER NOT NULL,
    predicted_class_name   TEXT NOT NULL,
    confidence      FLOAT NOT NULL,
    all_confidences JSONB,
    inference_time_ms FLOAT,
    latitude        FLOAT,
    longitude       FLOAT,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    local_id        INTEGER
);

CREATE INDEX IF NOT EXISTS idx_predictions_user_id ON predictions(user_id);
CREATE INDEX IF NOT EXISTS idx_predictions_created_at ON predictions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_predictions_leaf_type ON predictions(leaf_type);

-- RLS: User can only access own predictions
ALTER TABLE predictions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own predictions" ON predictions;
CREATE POLICY "Users can view own predictions"
    ON predictions FOR SELECT
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own predictions" ON predictions;
CREATE POLICY "Users can insert own predictions"
    ON predictions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own predictions" ON predictions;
CREATE POLICY "Users can update own predictions"
    ON predictions FOR UPDATE
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own predictions" ON predictions;
CREATE POLICY "Users can delete own predictions"
    ON predictions FOR DELETE
    USING (auth.uid() = user_id);

-- 2. Model registry table (public read, admin write)
CREATE TABLE IF NOT EXISTS model_registry (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    leaf_type       TEXT NOT NULL UNIQUE,
    display_name    TEXT NOT NULL,
    version         TEXT NOT NULL,
    file_url        TEXT,
    sha256_checksum TEXT NOT NULL,
    num_classes     INTEGER NOT NULL,
    class_labels    JSONB NOT NULL,
    accuracy_top1   FLOAT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE model_registry ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read model registry" ON model_registry;
CREATE POLICY "Anyone can read model registry"
    ON model_registry FOR SELECT
    USING (true);

-- 3. Seed model registry with current models
INSERT INTO model_registry (leaf_type, display_name, version, sha256_checksum, num_classes, class_labels, accuracy_top1)
VALUES
    ('tomato', 'Tomato', '1.0.0', '',
     10, '["Bacterial_spot","Early_blight","Late_blight","Leaf_Mold","Septoria_leaf_spot","Spider_mites","Target_Spot","Yellow_Leaf_Curl_Virus","Mosaic_virus","Healthy"]',
     87.2),
    ('burmese_grape_leaf', 'Burmese Grape Leaf', '1.0.0', '',
     5, '["Anthracnose","Healthy","Insect Damage","Leaf Spot","Powdery Mildew"]',
     87.3)
ON CONFLICT (leaf_type) DO NOTHING;

-- 4. Storage buckets
INSERT INTO storage.buckets (id, name, public) VALUES ('prediction-images', 'prediction-images', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public) VALUES ('models', 'models', true)
ON CONFLICT (id) DO NOTHING;

-- 5. Storage RLS policies
DROP POLICY IF EXISTS "Users upload own images" ON storage.objects;
CREATE POLICY "Users upload own images"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'prediction-images' AND
        (storage.foldername(name))[1] = auth.uid()::text
    );

DROP POLICY IF EXISTS "Users read own images" ON storage.objects;
CREATE POLICY "Users read own images"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'prediction-images' AND
        (storage.foldername(name))[1] = auth.uid()::text
    );

DROP POLICY IF EXISTS "Public read models" ON storage.objects;
CREATE POLICY "Public read models"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'models');
