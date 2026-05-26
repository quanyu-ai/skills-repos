---
name: database-config
description: 数据库配置管理技能，用于管理和配置测试版、演示版、生产版的数据库连接、初始化和迁移。
metadata: {"openclaw":{"emoji":"🗄️"}}
---

# database-config - 数据库配置管理技能 🗄️

> 专门用于管理和配置各个环境的数据库连接、初始化和迁移。

## 🎯 触发场景

- 需要为测试版、演示版、生产版配置不同的数据库连接
- 需要在部署前初始化数据库
- 需要执行数据库迁移
- 需要验证数据库连接的健康状态
- 需要管理数据库备份和恢复

## 📋 功能清单

### 核心功能

#### 1. 环境数据库配置
- ✅ 支持按环境（test/demo/prod）配置不同的数据库连接
- ✅ 支持多种数据库类型：PostgreSQL、MySQL、Redis
- ✅ 支持通过 environments.json 配置数据库连接信息

#### 2. 数据库初始化
- ✅ 支持数据库创建和用户授权
- ✅ 支持初始化数据导入
- ✅ 支持数据库备份和恢复

#### 3. 数据库迁移
- ✅ 支持 Prisma 迁移
- ✅ 支持其他 ORM 的迁移

#### 4. 健康检查
- ✅ 数据库连接检查
- ✅ 数据库性能监控
- ✅ 数据库状态报告

#### 5. 部署集成
- ✅ 与 deploy-app 技能集成
- ✅ 部署前检查数据库连接
- ✅ 部署后执行数据库迁移

### 扩展功能

#### 6. 数据库管理
- ✅ 支持查看数据库结构
- ✅ 支持查看数据库连接状态
- ✅ 支持查看数据库性能指标

#### 7. 安全管理
- ✅ 支持数据库用户管理
- ✅ 支持数据库权限管理
- ✅ 支持数据库连接加密

## 📚 使用方法

### 配置数据库连接

在 `skills/deploy-app/config/environments.json` 中添加数据库配置：

```json
{
  "environments": {
    "test": {
      "host": "localhost",
      "ssh_user": "deploy",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_base_path": "/var/www/test",
      "database": {
        "type": "postgresql",
        "host": "localhost",
        "port": 5432,
        "database": "smartops_test",
        "username": "test_user",
        "password": "test_password"
      },
      "apps": {
        "smartops": {
          "port": 3105,
          "pm2_name": "test-smartops"
        }
      }
    },
    "demo": {
      "host": "localhost",
      "ssh_user": "deploy",
      "ssh_key": "~/.ssh/deploy_local",
      "deploy_mode": "pm2",
      "deploy_base_path": "/var/www/demo",
      "database": {
        "type": "postgresql",
        "host": "localhost",
        "port": 5432,
        "database": "smartops_demo",
        "username": "demo_user",
        "password": "demo_password"
      },
      "apps": {
        "console": {
          "port": 3101,
          "pm2_name": "demo-console"
        }
      }
    },
    "prod": {
      "host": "PLACEHOLDER_PROD_HOST",
      "ssh_user": "deploy",
      "ssh_key": "~/.ssh/deploy_prod",
      "deploy_mode": "docker",
      "deploy_base_path": "/var/www/prod",
      "database": {
        "type": "postgresql",
        "host": "prod-db-host",
        "port": 5432,
        "database": "smartops_prod",
        "username": "prod_user",
        "password": "prod_password"
      },
      "apps": {}
    }
  }
}
```

### 初始化数据库

```bash
bash scripts/init-db.sh <env>
```

### 执行数据库迁移

```bash
bash scripts/migrate-db.sh <env>
```

### 检查数据库健康状态

```bash
bash scripts/check-db.sh <env>
```

### 备份数据库

```bash
bash scripts/backup-db.sh <env>
```

### 恢复数据库

```bash
bash scripts/restore-db.sh <env> <backup-file>
```

## 🔧 技能架构

### 文件结构

```
skills/database-config/
├── SKILL.md                     # 技能描述文件
├── README.md                    # 详细使用说明
└── scripts/
    ├── init-db.sh               # 数据库初始化脚本
    ├── migrate-db.sh            # 数据库迁移脚本
    ├── check-db.sh              # 数据库健康检查脚本
    ├── backup-db.sh             # 数据库备份脚本
    ├── restore-db.sh            # 数据库恢复脚本
    └── utils/
        ├── db-utils.sh          # 数据库工具函数
        └── config-utils.sh      # 配置工具函数
```

### 依赖工具

- PostgreSQL 客户端：psql
- MySQL 客户端：mysql
- Redis 客户端：redis-cli
- Prisma CLI：用于 Prisma 迁移
- jq：用于 JSON 处理

## 📊 与其他技能的关系

### 与 deploy-app 技能的关系

database-config 技能与 deploy-app 技能集成，提供以下功能：

1. **部署前检查**：在部署前检查数据库连接是否正常
2. **部署后迁移**：在部署后执行数据库迁移
3. **健康检查**：在部署后检查数据库健康状态
4. **环境配置**：通过 environments.json 统一管理环境配置

### 与其他技能的关系

- **与 solution-design 技能的关系**：在方案设计阶段规划数据库结构
- **与 requirement 技能的关系**：在需求阶段明确数据库需求
- **与 project-mgmt 技能的关系**：在项目管理阶段跟踪数据库任务

## 🚀 快速开始

### 安装依赖

```bash
cd /var/lib/openclaw/.openclaw/workspace/skills/database-config
bash scripts/init-deps.sh
```

### 初始化技能

```bash
bash scripts/init-skill.sh
```

### 测试技能

```bash
bash scripts/test-skill.sh
```

## 📝 开发计划

### Phase 1：基础功能（已完成）

- ✅ 技能框架和目录结构
- ✅ 数据库配置管理
- ✅ 数据库初始化脚本
- ✅ 数据库健康检查脚本
- ✅ 基本的错误处理

### Phase 2：核心功能（进行中）

- 🔄 数据库迁移功能
- 🔄 数据库备份和恢复功能
- 🔄 与 deploy-app 技能的集成
- 🔄 支持多种数据库类型

### Phase 3：高级功能（待开始）

- ⏳ 数据库性能监控
- ⏳ 数据库安全管理
- ⏳ 数据库自动优化
- ⏳ 数据库容量规划

## 📞 支持

如有问题或建议，请联系：

- **开发团队**：龙哥团队
- **文档**：SKILL.md 和 README.md
- **示例**：查看 `examples/` 目录

---

*本技能持续更新，如有问题请及时反馈。*
