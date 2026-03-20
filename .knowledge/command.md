
### COMMAND FOR ME (NOT FOR AI)
zig build -Doptimize=ReleaseSmall
zig build -Doptimize=ReleaseFast 

zig build -Doptimize=ReleaseSmall && cp zig-out/bin/nullclaw ../dist/bin/nullclaw
zig build -Doptimize=ReleaseFast && cp zig-out/bin/nullclaw ../dist/bin/nullclaw



nullclaw gateway

killall nullclaw


CUSTOM
nullclaw workspace append


-- sửa .envrc cần chạy 
direnv allow 


## SLACK COMMAND 

# Search and add context to agent
:mem all
:mem last 30
:mem <search>

# Sync 
:sync 

# Call actor (Subprocess - spawn process)
/<actor-name>
EX: /dev, /mentor, /cdev, /cmentor

