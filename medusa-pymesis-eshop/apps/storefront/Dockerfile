FROM node:20-alpine AS build
WORKDIR /repo
ARG NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY
ARG NEXT_PUBLIC_MEDUSA_BACKEND_URL
ENV NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY=$NEXT_PUBLIC_MEDUSA_PUBLISHABLE_KEY
ENV NEXT_PUBLIC_MEDUSA_BACKEND_URL=$NEXT_PUBLIC_MEDUSA_BACKEND_URL
RUN apk add --no-cache ca-certificates
COPY apps/storefront/pymesis-ca.crt /usr/local/share/ca-certificates/pymesis-ca.crt
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/pymesis-ca.crt
COPY package*.json ./
COPY apps/storefront/package*.json ./apps/storefront/
RUN npm ci
COPY apps/storefront ./apps/storefront
WORKDIR /repo/apps/storefront
RUN npm run build

FROM node:20-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/pymesis-ca.crt
COPY --from=build /usr/local/share/ca-certificates/pymesis-ca.crt /usr/local/share/ca-certificates/pymesis-ca.crt
RUN apk add --no-cache ca-certificates && update-ca-certificates
COPY --from=build /repo/apps/storefront/.next ./.next
COPY --from=build /repo/apps/storefront/public ./public
COPY --from=build /repo/apps/storefront/package*.json ./
COPY --from=build /repo/apps/storefront/next.config.js ./
COPY --from=build /repo/apps/storefront/check-env-variables.js ./
COPY --from=build /repo/node_modules ./node_modules
COPY --from=build /repo/apps/storefront/node_modules ./node_modules_local
RUN cp -r ./node_modules_local/* ./node_modules/ 2>/dev/null || true
EXPOSE 8000
CMD ["npm", "run", "start"]
