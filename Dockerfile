FROM node:22-alpine as build
WORKDIR /app/src
COPY package*.json ./
RUN npm ci
COPY . ./
RUN npm run build

FROM node:22-alpine
WORKDIR /usr/app
COPY --from=build /app/src/dist/connections ./
CMD node server/server.mjs
EXPOSE 8000