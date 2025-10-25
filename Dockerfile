FROM node:24-alpine AS build
WORKDIR /app/src
COPY package*.json ./
RUN npm install
COPY . ./
RUN npm run build

FROM node:24-alpine
WORKDIR /usr/app
COPY --from=build /app/src/dist/connections ./
CMD ["node", "server/server.mjs"]
EXPOSE 8000