FROM golang:1.23-alpine

# Add git in case some go modules require it
RUN apk add --no-cache git

WORKDIR /app

# Copy dependency files
COPY go.mod go.sum ./

# This is where your error happened. 
# We'll add a 'network=host' flag in the next step to fix it.
RUN go mod download

COPY . .

RUN go build -o main .

CMD ["./main"]