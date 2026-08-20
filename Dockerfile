FROM node:22-alpine AS builder

WORKDIR /app

# Build arguments for Vite client-side environment variables
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_SSO_PROVIDER
ARG VITE_ACCOUNT_URL
ARG VITE_POSTHOG_PROJECT_KEY
ARG VITE_SENTRY_ENVIRONMENT
ARG VITE_SENTRY_DSN

ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL
ENV VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY
ENV VITE_SSO_PROVIDER=$VITE_SSO_PROVIDER
ENV VITE_ACCOUNT_URL=$VITE_ACCOUNT_URL
ENV VITE_POSTHOG_PROJECT_KEY=$VITE_POSTHOG_PROJECT_KEY
ENV VITE_SENTRY_ENVIRONMENT=$VITE_SENTRY_ENVIRONMENT
ENV VITE_SENTRY_DSN=$VITE_SENTRY_DSN

# Install dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Copy application sources
COPY . .

# Build production bundle
RUN npm run build

# Runner stage
FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0

# Copy built application output
COPY --from=builder /app/.output ./.output
COPY --from=builder /app/package.json ./package.json

EXPOSE 3000

CMD ["node", ".output/server/index.mjs"]
