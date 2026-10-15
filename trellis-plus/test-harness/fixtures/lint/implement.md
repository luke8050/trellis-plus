# 实施计划：订单防重复提交

## 1 实施步骤

### 步骤 1：OrderService

- 文件：`src/main/java/com/acme/OrderService.java`
- 改什么：create(OrderDTO) 在 insert 前按 orderNo 查重，已存在抛 DuplicateOrderException

### 步骤 2：OrderController

- 文件：`src/main/java/com/acme/OrderController.java`
- 改什么：post 捕获 DuplicateOrderException，返回 409 和 ORDER_DUP

## 2 测试矩阵

| 对应R | 类 | 用例 | 类型 |
| --- | --- | --- | --- |
| R1 | OrderServiceTest | create_valid_savesAndReturnsId | 正常 |
| R1 | OrderServiceTest | create_firstOrderNo_inserts | 边界 |
| R1 | OrderServiceTest | create_duplicate_throws | 异常 |
| R3 | OrderServiceTest | create_null_throws | 异常 |
| R2 | OrderControllerTest | post_valid_returns200 | 正常 |
| R2 | OrderControllerTest | post_emptyOrderNo_returns400 | 边界 |
| R2 | OrderControllerTest | post_duplicate_returns409 | 异常 |

## 3 测试豁免

无
