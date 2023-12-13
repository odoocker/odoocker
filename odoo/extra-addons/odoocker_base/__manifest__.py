{
    'name': 'Odoocker Base',
    'summary': 'Supercharge Odoo with Odoocker',
    'description': '''
        Some Odoocker dependencies require to some custom values that we cover with this Addon for you.
    ''',
    'version': '1.0.0',
    'category': 'Technical',
    'license': 'LGPL-3',
    'author': 'Odoocker',
    'maintainer': 'Odoocker',
    'contributors': [
        'Yhael S <yhaelopez@gmail.com>'
    ],
    'depends': [
        'base'
    ],
    'data': [
        'data/ir_config_parameter.xml'
    ],
    'application': False,
    'installable': True,
    'auto_install': True
}
