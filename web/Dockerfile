# The React front end: built with Node, served by nginx.
#
#   docker build web
# (docker compose does this for you.)

# --- Build stage ------------------------------------------------------------
FROM node:22-alpine AS build
WORKDIR /app
# Dependencies first, so this layer is reused until package-lock.json changes.
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# --- Runtime stage ----------------------------------------------------------
# nginx serves the built files and forwards /api to the Haskell API, so the
# browser sees one origin (no CORS) exactly as with Vite in development.
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
