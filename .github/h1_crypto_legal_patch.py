from pathlib import Path

p=Path('humanity-live.html')
s=p.read_text(encoding='utf-8')

def replace_once(old,new,label):
    global s
    n=s.count(old)
    if n!=1:
        raise SystemExit(f'{label}: expected 1 match, found {n}')
    s=s.replace(old,new,1)

replace_once(
    '<meta name="humanity-build" content="V5.8.6-CHECKOUT-LOCK-UX-20260826" />',
    '<meta name="humanity-build" content="V5.8.7-CRYPTO-LEGAL-20260826" />',
    'meta build'
)

replace_once(
    '''      pay_currency:payCurrency,\n      ai_provider:activeWorld.id==='ai'?document.getElementById('aiProvider').value:null,\n      ai_model:null\n    });''',
    '''      pay_currency:payCurrency,\n      ai_provider:activeWorld.id==='ai'?document.getElementById('aiProvider').value:null,\n      ai_model:null,\n      legal_accepted:true,\n      legal_version:HUMANITY_LEGAL_VERSION\n    });''',
    'crypto legal payload'
)

replace_once(
    '''  }catch(err){\n    if(err.code==='NOWPAYMENTS_NOT_CONFIGURED'){''',
    '''  }catch(err){\n    if(err.code==='LEGAL_ACCEPTANCE_REQUIRED'){\n      toast('Checkout consent needs to be refreshed. Reopen REVIEW & PAY and accept the terms again.');\n    }else if(err.code==='NOWPAYMENTS_NOT_CONFIGURED'){''',
    'crypto legal error handling'
)

replace_once(
    "window.HUMANITY_BUILD='V5.8.6-CHECKOUT-LOCK-UX-20260826';",
    "window.HUMANITY_BUILD='V5.8.7-CRYPTO-LEGAL-20260826';",
    'runtime build'
)

p.write_text(s,encoding='utf-8')
