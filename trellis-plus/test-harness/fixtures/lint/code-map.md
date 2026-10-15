# 代码勘探：订单防重复提交

## 1 入口到数据的调用链

- 入口：src/main/java/com/acme/OrderController.java:6#post 直接委托 service
- 服务：src/main/java/com/acme/OrderService.java:7#create 先判空，再调用 mapper.insert
- 持久化：src/main/java/com/acme/OrderService.java:9#insert 返回新订单 id

## 2 被改符号的引用数

| 符号 | 命令 | 命中数 | 代表锚点 |
| --- | --- | --- | --- |
| OrderService#create | `git grep -n "OrderService.create"` | 1 | src/main/java/com/acme/OrderController.java:6#post |

## 3 同表/字段的其他读写

- NOT-FOUND: 其他按 order_no 读写订单表的 Mapper — 搜索：`git grep -n "order_no"`

## 4 现有测试与夹具

- NOT-FOUND: OrderService 的现有单测 — 搜索：`git grep -n "OrderServiceTest"`

## 5 同类实现与项目约定

- 空入参统一抛 IllegalArgumentException：src/main/java/com/acme/OrderService.java:8#create

## 6 对外契约

- POST /orders 由 OrderController.post 提供，现状见 src/main/java/com/acme/OrderController.java:6#post
