# syntax=docker/dockerfile:1
# Railway builds with the repository root as the Docker context, so all COPY
# paths are prefixed with `backend/`.

# ---- Build stage: compile TypeScript ----
FROM node:20-alpine AS build
WORKDIR /app/backend

COPY backend/package*.json ./
RUN npm ci

COPY backend/tsconfig.json ./
COPY backend/src ./src
RUN npm run build

# ---- Runtime stage: production deps + compiled output only ----
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

COPY backend/package*.json ./backend/
RUN cd backend && npm ci --omit=dev

COPY --from=build /app/backend/dist ./backend/dist

EXPOSE 3000

CMD ["node", "backend/dist/app.js"]
