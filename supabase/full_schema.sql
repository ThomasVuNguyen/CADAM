-- ==============================================================================
-- CADAM Full Database Schema Setup for Supabase
-- ==============================================================================

-- 1. Storage Buckets Setup
INSERT INTO storage.buckets (id, name, public)
VALUES 
    ('images', 'images', false),
    ('meshes', 'meshes', false),
    ('previews', 'previews', false),
    ('temp-multiview', 'temp-multiview', true)
ON CONFLICT (id) DO NOTHING;

-- 2. Custom Types / Enums
DO $$ BEGIN
    CREATE TYPE "public"."conversation-type" AS ENUM ('parametric', 'creative');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."generation-status" AS ENUM ('pending', 'success', 'failure');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."mesh_model_type" AS ENUM ('quality', 'fast');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."mesh_file_type" AS ENUM ('glb', 'stl', 'obj', 'fbx');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."privacy_type" AS ENUM ('public', 'private');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."prompt_type" AS ENUM ('mesh', 'image', 'chat');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- 3. Profiles Table
CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "notifications_enabled" boolean DEFAULT false NOT NULL,
    "avatar_path" "text" DEFAULT NULL,
    CONSTRAINT "profiles_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE
);

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can manage their own profile" ON "public"."profiles";
CREATE POLICY "Users can manage their own profile" ON "public"."profiles" USING ( (SELECT "auth"."uid"()) = "user_id" );

-- 4. Conversations Table
CREATE TABLE IF NOT EXISTS "public"."conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "type" "public"."conversation-type" DEFAULT 'parametric'::"public"."conversation-type" NOT NULL,
    "privacy" "public"."privacy_type" DEFAULT 'private'::"public"."privacy_type" NOT NULL,
    "current_message_leaf_id" "uuid",
    "settings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "conversations_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "conversations_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS conversations_created_at_idx ON "public"."conversations" USING btree (created_at);
CREATE INDEX IF NOT EXISTS conversations_updated_at_idx ON "public"."conversations" USING btree (updated_at);
CREATE INDEX IF NOT EXISTS conversations_user_id_idx ON "public"."conversations" USING btree (user_id);

ALTER TABLE "public"."conversations" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can view a public conversation" ON "public"."conversations";
CREATE POLICY "Anyone can view a public conversation" ON "public"."conversations" FOR SELECT TO "authenticated", "anon" USING (("privacy" = 'public'::"public"."privacy_type"));
DROP POLICY IF EXISTS "Users can manage their own conversations" ON "public"."conversations";
CREATE POLICY "Users can manage their own conversations" ON "public"."conversations" USING ( (SELECT "auth"."uid"()) = "user_id" );

-- 5. Messages Table
CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "parts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "content" "jsonb",
    "rating" smallint DEFAULT '0'::smallint NOT NULL,
    "parent_message_id" "uuid",
    CONSTRAINT "messages_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "messages_role_check" CHECK (("role" = ANY (ARRAY['user'::"text", 'assistant'::"text"]))),
    CONSTRAINT "messages_payload_present" CHECK ((jsonb_array_length("parts") > 0) OR ("content" IS NOT NULL)),
    CONSTRAINT "messages_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS messages_conversation_id_idx ON "public"."messages" USING btree (conversation_id);

ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public conversations messages" ON "public"."messages";
CREATE POLICY "Public conversations messages" ON "public"."messages" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."conversations"
  WHERE (("conversations"."id" = "messages"."conversation_id") AND ("conversations"."privacy" = 'public'::"public"."privacy_type")))));
DROP POLICY IF EXISTS "Users can manage messages in their conversations" ON "public"."messages";
CREATE POLICY "Users can manage messages in their conversations" ON "public"."messages" USING (((SELECT "auth"."uid"()) IN ( SELECT "conversations"."user_id"
   FROM "public"."conversations"
  WHERE ("conversations"."id" = "messages"."conversation_id"))));

-- 6. Images Table
CREATE TABLE IF NOT EXISTS "public"."images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."generation-status" DEFAULT 'pending'::"public"."generation-status" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "image_generation_call_id" "text",
    "prompt" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "images_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "images_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT "images_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_images_image_generation_call_id ON "public"."images" USING "btree" ("image_generation_call_id");

ALTER TABLE "public"."images" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public conversations images" ON "public"."images";
CREATE POLICY "Public conversations images" ON "public"."images" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."conversations"
  WHERE (("conversations"."id" = "images"."conversation_id") AND ("conversations"."privacy" = 'public'::"public"."privacy_type")))));
DROP POLICY IF EXISTS "User can manage their data" ON "public"."images";
CREATE POLICY "User can manage their data" ON "public"."images" TO "authenticated" USING ((( SELECT "auth"."uid"()) = "user_id")) WITH CHECK ((( SELECT "auth"."uid"()) = "user_id"));

-- 7. Meshes Table
CREATE TABLE IF NOT EXISTS "public"."meshes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."generation-status" DEFAULT 'pending'::"public"."generation-status" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "images" "uuid"[],
    "conversation_id" "uuid" NOT NULL,
    "prompt" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "file_type" "public"."mesh_file_type" DEFAULT 'glb'::"public"."mesh_file_type" NOT NULL,
    CONSTRAINT "meshes_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "meshes_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT "meshes_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE
);

ALTER TABLE "public"."meshes" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Everyone can view meshes associated with public conversations" ON "public"."meshes";
CREATE POLICY "Everyone can view meshes associated with public conversations" ON "public"."meshes" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."conversations"
  WHERE (("conversations"."id" = "meshes"."conversation_id") AND ("conversations"."privacy" = 'public'::"public"."privacy_type")))));
DROP POLICY IF EXISTS "Users can manage their meshes" ON "public"."meshes";
CREATE POLICY "Users can manage their meshes" ON "public"."meshes" USING ( (SELECT "auth"."uid"()) = "user_id" );

-- 8. Prompts Table
CREATE TABLE IF NOT EXISTS "public"."prompts" (
    "id" bigint generated by default as identity not null,
    "created_at" timestamp with time zone not null default now(),
    "user_id" "uuid" NOT NULL,
    "type" "public"."prompt_type" DEFAULT 'chat'::"public"."prompt_type" NOT NULL,
    CONSTRAINT "prompts_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "prompts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE
);

ALTER TABLE "public"."prompts" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view their own prompts" ON "public"."prompts";
CREATE POLICY "Users can view their own prompts" ON "public"."prompts" FOR SELECT USING ((SELECT "auth"."uid"()) = "user_id");

-- 9. Previews Table
CREATE TABLE IF NOT EXISTS "public"."previews" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "public"."generation-status" DEFAULT 'pending'::"public"."generation-status" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "mesh_id" "uuid" NOT NULL,
    CONSTRAINT "previews_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "previews_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT "previews_conversation_id_fkey" FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT "previews_mesh_id_fkey" FOREIGN KEY (mesh_id) REFERENCES meshes(id) ON DELETE CASCADE
);

ALTER TABLE "public"."previews" ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can manage their own previews" ON "public"."previews";
CREATE POLICY "Users can manage their own previews" ON "public"."previews" USING ( (SELECT "auth"."uid"()) = "user_id" );

-- 10. Triggers & Functions
CREATE OR REPLACE FUNCTION "public"."update_conversation_leaf"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE conversations SET 
    current_message_leaf_id = NEW.id,
    updated_at = now()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "update_leaf_trigger" ON "public"."messages";
CREATE TRIGGER "update_leaf_trigger" AFTER INSERT ON "public"."messages" FOR EACH ROW EXECUTE FUNCTION "public"."update_conversation_leaf"();

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE 'plpgsql';

DROP TRIGGER IF EXISTS update_previews_updated_at ON "public"."previews";
CREATE TRIGGER update_previews_updated_at 
    BEFORE UPDATE ON "public"."previews" 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (user_id, full_name)
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data->>'full_name',
      split_part(NEW.email, '@', 1)
    )
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 11. Storage Policies
DROP POLICY IF EXISTS "Give users access to own folder images_select" ON storage.objects;
CREATE POLICY "Give users access to own folder images_select" ON storage.objects FOR SELECT TO public USING (bucket_id = 'images' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder images_insert" ON storage.objects;
CREATE POLICY "Give users access to own folder images_insert" ON storage.objects FOR INSERT TO public WITH CHECK (bucket_id = 'images' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder images_update" ON storage.objects;
CREATE POLICY "Give users access to own folder images_update" ON storage.objects FOR UPDATE TO public USING (bucket_id = 'images' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder images_delete" ON storage.objects;
CREATE POLICY "Give users access to own folder images_delete" ON storage.objects FOR DELETE TO public USING (bucket_id = 'images' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder meshes_select" ON storage.objects;
CREATE POLICY "Give users access to own folder meshes_select" ON storage.objects FOR SELECT TO public USING (bucket_id = 'meshes' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder meshes_insert" ON storage.objects;
CREATE POLICY "Give users access to own folder meshes_insert" ON storage.objects FOR INSERT TO public WITH CHECK (bucket_id = 'meshes' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder meshes_update" ON storage.objects;
CREATE POLICY "Give users access to own folder meshes_update" ON storage.objects FOR UPDATE TO public USING (bucket_id = 'meshes' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder meshes_delete" ON storage.objects;
CREATE POLICY "Give users access to own folder meshes_delete" ON storage.objects FOR DELETE TO public USING (bucket_id = 'meshes' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Public conversations allow anyone to view images_select" ON storage.objects;
CREATE POLICY "Public conversations allow anyone to view images_select" ON storage.objects FOR SELECT TO anon, authenticated USING (((bucket_id = 'images'::text) AND (EXISTS ( SELECT 1 FROM conversations WHERE ((conversations.privacy = 'public') AND ((conversations.id)::text = (storage.foldername(objects.name))[2]))))));

DROP POLICY IF EXISTS "Public conversations allow anyone to view meshes_select" ON storage.objects;
CREATE POLICY "Public conversations allow anyone to view meshes_select" ON storage.objects FOR SELECT TO anon, authenticated USING (((bucket_id = 'meshes'::text) AND (EXISTS ( SELECT 1 FROM conversations WHERE ((conversations.privacy = 'public') AND ((conversations.id)::text = (storage.foldername(objects.name))[2]))))));

DROP POLICY IF EXISTS "Give users access to own folder previews_select" ON storage.objects;
CREATE POLICY "Give users access to own folder previews_select" ON storage.objects FOR SELECT TO public USING (bucket_id = 'previews' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder previews_insert" ON storage.objects;
CREATE POLICY "Give users access to own folder previews_insert" ON storage.objects FOR INSERT TO public WITH CHECK (bucket_id = 'previews' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder previews_update" ON storage.objects;
CREATE POLICY "Give users access to own folder previews_update" ON storage.objects FOR UPDATE TO public USING (bucket_id = 'previews' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Give users access to own folder previews_delete" ON storage.objects;
CREATE POLICY "Give users access to own folder previews_delete" ON storage.objects FOR DELETE TO public USING (bucket_id = 'previews' AND (select auth.uid()::text) = (storage.foldername(name))[1]);

DROP POLICY IF EXISTS "Allow service role to upload temp multiview images" ON storage.objects;
CREATE POLICY "Allow service role to upload temp multiview images" ON storage.objects FOR INSERT TO service_role WITH CHECK (bucket_id = 'temp-multiview');

DROP POLICY IF EXISTS "Allow public read access to temp multiview images" ON storage.objects;
CREATE POLICY "Allow public read access to temp multiview images" ON storage.objects FOR SELECT TO public USING (bucket_id = 'temp-multiview');

DROP POLICY IF EXISTS "Allow service role to delete temp multiview images" ON storage.objects;
CREATE POLICY "Allow service role to delete temp multiview images" ON storage.objects FOR DELETE TO service_role USING (bucket_id = 'temp-multiview');
