#!/usr/bin/env python  
# -*- coding: utf-8 -*-

from tango.ui import tables
from tango.ui.tables import Attrs

from .models import User, Role, Domain

#### Tables
class UserTable(tables.Table):

    helpdoc = u"用户表: 管理维护用户信息"

    edit   = tables.Action(name=u'编辑', endpoint='users.users_edit')
    delete = tables.Action(name=u'删除', endpoint='users.users_delete', modalable=True)
    reset  = tables.Action(name=u'重置密码', endpoint='users.reset_password')
    
    check      = tables.CheckBoxColumn()
    
    username       = tables.Column(u'用户名', orderable=True)
    name           = tables.Column(u'真实姓名')
    role_name      = tables.Column(u'角色名称', orderable=True, accessor='role.name')
    domain         = tables.Column(u'管理域', orderable=True, accessor='domain.name')
    email          = tables.EmailColumn(u'邮箱')
    department     = tables.Column(u'部门')
    telephone      = tables.Column(u'电话')

    class Meta():
        model = User
        order_by = 'username'


class RoleTable(tables.Table):
    edit   = tables.Action(name=u'编辑', endpoint='users.roles_edit')
    delete = tables.Action(name=u'删除', endpoint='users.roles_delete', modalable=True)
    
    check  = tables.CheckBoxColumn()
    
    name        = tables.Column(u'角色名称')
    description = tables.Column(u'描述')

    class Meta():
        model = Role
        order_by = 'id'


class DomainTable(tables.Table):
    edit   = tables.Action(name=u'编辑', endpoint='users.domains_edit')
    delete = tables.Action(name=u'删除', endpoint='users.domains_delete', modalable=True)

    check  = tables.CheckBoxColumn()
    
    name        = tables.Column(u'名称')
    description = tables.Column(u'描述')

    class Meta():
        model = Domain
        order_by = 'id'
