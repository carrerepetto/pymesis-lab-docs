FROM node:20-alpine AS build
WORKDIR /repo
COPY package*.json ./
COPY apps/backend/package*.json ./apps/backend/
RUN npm ci
COPY apps/backend ./apps/backend
WORKDIR /repo/apps/backend
RUN npx medusa build

FROM node:20-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /repo/apps/backend/.medusa/server ./
RUN npm install --omit=dev
EXPOSE 9000
CMD ["npm", "run", "start"]
