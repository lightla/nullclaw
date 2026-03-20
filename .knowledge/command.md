
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

# Search and add context to actor 
:mem all
:mem last 30
:mem <search>

EX: 
    :mem last 30
    Hi /dev, what is my name?     

Hi 

# Sync 
:sync 
// mỗi actor tự động sync data trong sqllite riêng (mem riêng)

# Del (lệnh xóa message trong slack, cần có `sys.channels.slack` trong actor.config.json)
:del 30 
:del all

# Call actor (Subprocess - spawn process)
/<actor-name>
EX: /dev, /mentor, /cdev, /cmentor

# Show all action
:help 
