{
    'name': 'Module Name',
    'summary': 'Module Summary',
    'description': '''
        Multi-Line Module Description
        Goes Here
    ''',
    'version': '1.0.0', # (X.Y.Z.W) X: Odoo Version (not present), Y: Major Upgrade, Z: Bugfix, W: Minor Upgrade
    'category': 'Uncategorized', # Possible values: [https://github.com/odoo/odoo/blob/16.0/odoo/addons/base/data/ir_module_category_data.xml]
    'license': 'LGPL-3',
    'sequence': 100, # Order in which the module will be displayed
    # Author, Pricing, Licensing, and Support Info
    'author': 'Your Company',
    'website': 'https://yourcompany.com',
    'maintainer': 'Your Company DevTeam',
    'contributors': [
        'Name 1 <email@example.com>',
        'Name 2 <email2@example.com>'
    ],
    'price': 0.0,
    'currency': 'MXN',
    'support': 'your-email@yourcompany.com',
    'live_test_url': 'http://www.yourcompany.com/live_test',
    # Technical Info
    'depends': [
        'base',
        # other dependent modules...
    ],
    'external_dependencies': {
        'python': [
            # python packages...
        ],
        'bin': [
            # binary packages...
        ],
    },
    'data': [
        'security/ir.model.access.csv'
        'views/view_file.xml',
        # ... other xml, csv data files
    ],
    'demo': [
        'demo/demo_data.xml'
        # ... other demo data files
    ],
    'qweb': [
        'static/src/xml/template.xml'
        # ... other qweb templates
    ],
    'assets': {
        'web.assets_backend': [
            'module_name/static/src/js/file.js',
            'module_name/static/src/css/style.css'
            # ... other assets
        ],
        'web.assets_qweb': [
            'module_name/static/src/xml/template.xml'
            # ... other qweb templates
        ],
    },
    # Module Status
    'application': False,
    'installable': True,
    'auto_install': False
}
