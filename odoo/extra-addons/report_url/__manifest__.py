{
    'name': 'Report URL',
    'summary': 'Adds Report URL to Odoo Container',
    'description': '''
        Odoo Containers doesn't come with report.url param out of the box, so we add it for you to work with Odoocker.
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
