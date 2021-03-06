﻿// textwnd.as
/*
  Тут часть кода, работающая с текстовыми окнами
*/
#pragma once
#include "../../all.h"

TextWnd&& activeTextWnd;

// Это интерфейс обработчика событий в тексте.
// В-зависимости от назначенного текстовому документу расширения (встроенный язык, язык запросов и т.п.)
// создается соответствующий расширению текстовый процессор. Именно он и обрабатывает события в текстовом окне
interface TextProcessor {
    // Подключение/отключение к документу
    void setTextDoc(TextDoc&& textDoc);
    // Подключение нового окна редактора
    void connectEditor(TextWnd&& editor);
    // Обработка после WM_CHAR
    void afterChar(TextWnd&& editor, uint16 symbol);
    // Обработка при WM_KEYDOWN, WM_SYSKEYDOWN
    bool onKeyDown(TextWnd&& editor, WPARAM wParam, LPARAM lParam);
    // Из списка снегопата был вставлен элемент
    void itemInserted(TextWnd&& editor, SmartBoxInsertableItem&& item);
};

// Просто базовый интерфейс для хранения текстовым процессором данных для конкретного редактора
interface EditorData {};

// Реализация пустого текстового процессора, ничего не делает
class EmptyTextProcessor : TextProcessor {
    void setTextDoc(TextDoc&& textDoc) {}
    void connectEditor(TextWnd&& editor) { &&editor.editorData = null; }
    void afterChar(TextWnd&& editor, uint16 symbol) {}
    bool onKeyDown(TextWnd&& editor, uint wParam, uint lParam) { return false; }
    void itemInserted(TextWnd&& editor, SmartBoxInsertableItem&& item) {}
};

/*
    Основная функция вставки текста в текстовый редактор.
    Вставляет в текущее положение редактора (как-будто нажали Ctrl+V)
    При необходимости дополняет многострочный текст нужным отступом,
    взависимости от вставляемого положения.
    При необходимости сбрасывает кэш парсера строк 1С.
    В-принципе, необходимость возникает всегда :)
    иначе очень весёлые глюки. Хотя когда нужно сделать несколько вставок подряд,
    кэш можно сбросить только после последней вставки.
*/
void insertInSelection(ITextEditor&& pEditor, TextManager&& pTM, ITextManager&& pITM, const string& txt, bool bClearCache, bool needIndent) {
    string text(txt);
    TextPosition tpStart, tpCaretAfter;
    pEditor.getSelection(tpStart, tpCaretAfter, false);
    // Далее надо определить конечное положение селекшена, конечное положение каретки,
    // и сделать по необходимости отступы
    if (text.find('\n') < 0) {  // Однострочный текст, с ним проще
        tpCaretAfter = tpStart;
        int caret = text.find(symbCaret);
        if (caret >= 0) {
            tpCaretAfter.col += caret;
            text.remove(caret);
        } else
            tpCaretAfter.col += text.length;
    } else {
        if (needIndent) {
            // Формируем отступ. Для этого к каждой строке вставляемого текста, начиная со второй
            // нужно добавить такой-же отступ, как у строки в редакторе
            string indent = getTextLine(pTM, tpStart.line).rtrim("\r\n").padRight(' ', tpStart.col - 1).match(indentRex).text(0, 0);
            if (indent.length > 0)
                text.replace("\n", "\n" + indent);
        }
        // Находим конечное положение
        tpCaretAfter = tpStart;
        for (int i = 0, l = text.length; i < l; i++) {
            uint16 symbol = text[i];
            if ('\n' == symbol) {
                tpCaretAfter.line++;
                tpCaretAfter.col = 1;
            } else if (symbCaret == symbol) {
                text.remove(i);
                break;
            } else
                tpCaretAfter.col++;
        }
    }
    // Вставляем текст
    pEditor.setSelectionText(text);
    pEditor.setCaretPosition(tpCaretAfter, false);
    pEditor.scrollToCaretPos();

    if (bClearCache) {
        ITextParserCache&& pCache = pITM.unk;
        //if (pCache !is null)
            pCache.clearCache();
    }
    // Обновляем все другие окна этого текста
    ITextManager_Operations&& vu = pITM.unk;
    //if (vu !is null)
        vu.updateAllViews();
}

TextProcessor&& createTextProcessor(const Guid& g) {
    if (g == gTextExtModule || g == gTextExtModule1) {
        return ModuleTextProcessor();
    }
    return EmptyTextProcessor();
}

TextDocStorage textDocStorage;

class TextDocStorage {
    array<TextDoc&&> openedDocs;

    TextDoc&& find(ITextManager&& itm) {
        for (uint idx = 0, size = openedDocs.length(); idx < size; idx++) {
            if (openedDocs[idx].itm is itm)
                return openedDocs[idx];
        }
        return null;
    }
    TextDoc&& find(TextManager&& tm) {
        for (uint idx = 0, size = openedDocs.length(); idx < size; idx++) {
            if (openedDocs[idx].tm is tm)
                return openedDocs[idx];
        }
        return null;
    }
    void store(TextDoc&& tdoc) { openedDocs.insertLast(&&tdoc); }
    void remove(TextDoc&& doc) {
        for (uint idx = 0, size = openedDocs.length(); idx < size; idx++) {
            if (openedDocs[idx] is doc) {
                openedDocs.removeAt(idx);
                break;
            }
        }
    }
	void disableTextWork() {
		for (uint i = 0; i < openedDocs.length; i++) {
			TextDoc&& td = openedDocs[i];
			td.setTextExtenderType(IID_NULL);
		}
	}
	void enableTextWork() {
		for (uint i = 0; i < openedDocs.length; i++) {
			TextDoc&& td = openedDocs[i];
			ITextManager_Operations&& to = cast<IUnknown>(td.itm);
			Guid textExtender;
			to.getExtenderCLSID(textExtender);
			td.setTextExtenderType(textExtender);
		}
	}
};

// Вызывается из перехвата при создании окна текстового редактора
void onCreateTextWnd(IWindowView&& pWnd, bool bControl) {
    if (bControl) {
        IControlDesign&& ctrl = pWnd.unk;
        if (ctrl !is null && ctrl.getMode() != ctrlRunning)
            return; // С контролами на формах не работаем
    }
    TextWnd wnd(pWnd, bControl);
    ITextManager&& itm;
    wnd.ted.getITextManager(itm);
    TextDoc&& tdoc = textDocStorage.find(itm);
    if (tdoc is null) {
        //Print("Text doc not found");
        &&tdoc = TextDoc();
        &&tdoc.itm = itm;
        &&tdoc.tm = itm.getTextManager();
        ITextManager_Operations&& to = itm.unk;
        Guid textExtender;
        to.getExtenderCLSID(textExtender);
        tdoc.setTextExtenderType(textExtender);
        textDocStorage.store(tdoc);
    } //else Print("Found old text doc");
    tdoc.attachView(wnd);
	if (oneDesigner !is null)
        oneDesigner._fireCreateTextWindow(wnd);
}

// Вызывается из перехвата при смене расширения текстового редактора
// (т.е. в меню текст выбрали тип текста - Встроеный язык, язык запросов, и т.п.)
void changeTextExtender(ITextManager&& itm, const Guid& textExtender) {
    TextDoc&& tdoc = textDocStorage.find(itm);
    if (tdoc !is null)
        tdoc.setTextExtenderType(textExtender);
}

NoCaseMap<TextDocMdInfo&&> openedMdObjects;
string keyForSearchOpenedMD(IMDObject&& obj, const Guid& propUuid) {
    return "" + obj.self + "|" + propUuid;
}

class TextDocMdInfo {
    TextDocMdInfo(IAssistantData&& data, TextDoc&& doc) {
        &&owner = doc;
        IUnknown&& unk;
        data.object(unk);
        &&object = unk;
        &&extObject = data.extObject();
        mdPropUuid = data.propUuid();
        if (object !is null)
            &&container = getMDObjectWrapper(object).get_container()._container();
        openedMdObjects.insert(keyForSearchOpenedMD(object, mdPropUuid), this);
    }
    void detach() {
        openedMdObjects.remove(keyForSearchOpenedMD(object, mdPropUuid));
        &&owner = null;
		&&object = null;
		&&container = null;
		&&extObject = null;
    }
    TextDoc&& owner;
    IMDObject&& object;
    IMDContainer&& container;
    IUnknown&& extObject;
    Guid mdPropUuid;
};

// Класс, который хранит различную инфу о текстовом документе.
// Важно, у одного текстового документа может быть открыто несколько окон
class TextDoc {
    ITextManager&&   itm;
    TextManager&&    tm;
    TextProcessor&&  tp;
    array<TextWnd&&> views;
    TextDocMdInfo&&  mdInfo;
	TextEditorDocument&& editorDoc;
    ~TextDoc() {
        //Print("delete TextDoc");
    }
    void attachView(TextWnd&& wnd) {
        &&wnd.textDoc = this;
        views.insertLast(&&wnd);
        tp.connectEditor(wnd);
		&&wnd.editor = editorDoc.createEditor();
		wnd.editor.attach(wnd);
    }
    void detachView(TextWnd&& wnd) {
        if (wnd is activeTextWnd)
            &&activeTextWnd = null;
        for (uint idx = 0, size = views.length(); idx < size; idx++) {
            if (views[idx] is wnd) {
                views.removeAt(idx);
                break;
            }
        }
		wnd.editor.detach();
		&&wnd.editor = null;
        if (views.length() == 0) { // Закрыли последнее окно
			tp.setTextDoc(null);
			&&tp = null;
			if (mdInfo !is null) {
				mdInfo.detach();
				&&mdInfo = null;
			}
			editorDoc.detach();
			&&editorDoc = null;
            textDocStorage.remove(this);
        }
    }
    void setTextExtenderType(const Guid& g) {
		if (mdInfo is null && (g == gTextExtModule || g == gTextExtModule1)) {
			ITxtEdtExtender&& ext;
			getTxtEdtService().getExtender(ext, itm, g);
			ISettingsConsumer&& st = ext.unk;
            IAssistantData&& data;
			//dumpVtable(&&ext);
			//dumpVtable(&&st, "_stet");
			//Print("cons=" + st.self + " offset=" + (st.self + ModuleTxtExtSettingsMap));
            for (uint node = mem::dword[st.self + ModuleTxtExtSettingsMap]; node != 0; node = mem::dword[node]) {
                GuidRef&& pg = toGuid(node + 4);
                if (pg.ref == IID_IAssistantData) {
                    &&data = toIUnknown(mem::dword[node + 20]);
                    data.AddRef();
                    break;
                }
            }
            if (data !is null)
                &&mdInfo = TextDocMdInfo(data, this);
        }
		if (tp !is null)
			tp.setTextDoc(null);
        &&tp = createTextProcessor(g);
        tp.setTextDoc(this);
		if (editorDoc !is null)
			editorDoc.detach();
		&&editorDoc = editorsManager._createEditor(g);
		editorDoc.attach(this);

		for (uint k = 0, m = views.length; k < m; k++) {
			TextWnd&& tw = views[k];
			tp.connectEditor(tw);
			tw.editor.detach();
			&&tw.editor = editorDoc.createEditor();
			tw.editor.attach(tw);
		}
    }
    TextWnd&& findWnd(ITextEditor&& editor) {
        for (uint i = 0, im = views.length; i < im; i++) {
            TextWnd&& wnd = views[i];
            if (wnd.ted is editor)
                return wnd;
        }
        return null;
    }
};

class TextWnd {
    ASWnd&&        wnd;            // сабклассер текстового окна, перенаправляет указанные события оконной процедуры в скриптовый обработчик
    HWND           hWnd;           // WinAPI хэндл окна
    ITextEditor&&  ted;            // Интерфейс редактора 1С
    TextDoc&&      textDoc;        // Родительский объект, общий для всех окон одного текста
    EditorData&&   editorData;     // Данные, нужные для текстового процессора
    bool           isControl;      // Является ли окно текстовым контролом или полноценным view
    ITextWindow&&  iwnd;           // Скриптовая обертка
	TextEditorWindow&& editor;	   // реализация окна-редактора
    
    TextWnd(IWindowView&& v, bool isCtrl) {
        isControl = isCtrl;
        hWnd = v.hwnd();
		&&wnd = attachWndToFunction(hWnd, WndFunc(this.WndProc), defaultMessages());
        &&ted = v.unk;
    }
	array<uint> defaultMessages() {
		return array<uint> = { WM_KEYDOWN, WM_SYSKEYDOWN, WM_CHAR, WM_DESTROY, WM_SETFOCUS, WM_KILLFOCUS };
	}

	LRESULT WndProc(uint msg, WPARAM w, LPARAM l) {
		switch (msg) {
		case WM_SETFOCUS:
			&&activeTextWnd = this;
			break;
		case WM_KILLFOCUS:
			&&activeTextWnd = null;
			break;
		case WM_DESTROY:
			if (textDoc !is null)
				textDoc.detachView(this);
			if (iwnd !is null)		 // Если есть скриптовая обёртка
				iwnd._disconnect();  // отвяжемся от неё
			return wnd.doDefault();
		case WM_KEYDOWN:
		case WM_SYSKEYDOWN:
			if (onKeyDown(w, l))
				return 0;
			break;
		case WM_CHAR: {
			LRESULT res = wnd.doDefault();
			onChar(w);
			return res;
			}
		}
		return editor.wndProc(msg, w, l);
	}
    ~TextWnd() {
        //Print("delete TextWnd");
    }
    bool onKeyDown(WPARAM w, LPARAM l) {
		return textDoc.tp.onKeyDown(this, w, l);
    }
    void onChar(uint16 symb) {
        textDoc.tp.afterChar(this, symb);
    }
    ITextWindow&& getComWrapper() {
        if (iwnd is null)
            &&iwnd = ITextWindow(this);
        return iwnd;
    }
};

/*
Интерфейсы, служащие для работы с окном редактора текста - штатным или другим,
позволяющий использовать альтернативные текстовые редакторы.
*/

// Интерфейс для связи с текстовым документом.
class TextEditorDocument {
	TextDoc&& owner;
	void attach(TextDoc&& td)			{ &&owner = td; }
	void detach()						{ &&owner = null; }
	TextEditorWindow&& createEditor()	{ return TextEditorWindow(); }
};

// Интерфейс для взаимодействия с окном редактора. Один текстовый документ может
// одновременно иметь несколько окон редакторов. Снегопат сабклассирует окно
// штатного редактора и отдаёт обработку оконных сообщений назначенному редактору
class TextEditorWindow {
	TextWnd&& txtWnd;
	void attach(TextWnd&& tw)			{ &&txtWnd = tw; }
	void detach()						{ &&txtWnd = null; }
	// Обработчик оконной процедуры
	LRESULT wndProc(uint msg, WPARAM w, LPARAM l) {
		return txtWnd.wnd.doDefault();
	}
	// Функции для работы снегопатовского списка контекстной подсказки
	void getFontSize(Size& fontSize) {
		ITxtEdtOptions&& params = txtWnd.ted.unk;
		Font font;
		params.getFont(font);
		getLogFontSizes(font.lf, fontSize);
	}
	void createCaret(uint lineHeight) {
		CreateCaret(txtWnd.hWnd, 0, 2, lineHeight);
	}
	void showCaret() {
		ShowCaret(txtWnd.hWnd);
	}
	uint getTextWidth(const string& text, const Size& fontSize) {
		return fontSize.cx * text.length;
	}
};

// Интерфейс получателя уведомлений об изменениях в тексте документа
// Позволяет редактору реагировать на изменения текста, сделанными программно, не через редактор
interface TextModifiedReceiver {
	void onTextModified(TextManager& tm, const TextPosition& tpStart, const TextPosition& tpEnd, const string& newText);
};

// Интерфейс получателя уведомлений об изменениях в окне редактора, сделанных программно
interface SelectionChangedReceiver {
	// Программно изменили границы выделения в редакторе
	void onSelectionChanged(ITextEditor& editor, const TextPosition& tpStart, const TextPosition& tpEnd);
	// Вызван скроллинг окна до позиции каретки
	void onScrollToCaretPos(ITextEditor& editor);
	// Список штатной подсказки 1С запрашивает оконные координаты, где его показать
	bool getCaretPosForIS(ITEIntelliSence& teis, Point& caretPos, uint& lineHeight);
	// Проверить границы выделения в режиме ожидания
	void checkSelectionInIdle(ITextEditor& editor);
};

// Описание альтернативного редактора
interface EditorInfo {
	string name();					// Его имя
	string extention();				// Для какого расширения текстового редактора он предназначен (например, Встроенный язык)
	array<string>&& extGuids();		// Идентификаторы расширений текстового редактора, для которых он предназначен
	void activate();				// Вызывается при назначении этого типа редактора активным
	void doSetup();					// Вызов настройки редактора
	TextEditorDocument&& create();	// Создание редактора
};

// Обёртка вокруг EditorInfo для работы через SnegAPI
class ComEditorInfo {
	string _name;
	string _extention;
	ComEditorInfo(EditorInfo&& ei) {
		_name = ei.name();
		_extention = ei.extention();
	}
};

// Менеджер альтернативных редакторов
class EditorsManager {
	private array<EditorInfo&&> editors;
	private NoCaseMap<EditorInfo&&> editorForExtNames;
	private NoCaseMap<EditorInfo&&> editorForExtGuids;
	private UintMap<array<SelectionChangedReceiver&&>&&> selChangeSubscribers;
	private UintMap<array<TextModifiedReceiver&&>&&> textChangeSubscribers;

	private void checkSelectionInIdle() {
		for (auto it = selChangeSubscribers.begin(); !it.isEnd(); it++) {
			ITextEditor&& ted = toITextEditor(it.key);
			ted.AddRef();
			auto arr = it.value;
			for (uint i = 0; i < arr.length; i++)
				arr[i].checkSelectionInIdle(ted);
		}
	}

	// Создание редактора для указанного расширения текстового редактора
	TextEditorDocument&& _createEditor(const Guid& extGuid) {
		auto fnd = editorForExtGuids.find(string(extGuid));
		if (fnd.isEnd())
			return TextEditorDocument();
		return fnd.value.create();
	}
	// Регистрация вида редактора
	void _registerEditor(EditorInfo&& editorInfo) {
		editors.insertLast(editorInfo);
	}
	// Подписка на изменения в окне редактора
	void _subscribeToSelChange(ITextEditor& editor, SelectionChangedReceiver& receiver) {
		if (trSS.state == trapNotActive)
			idleHandlers.insertLast(PVV(this.checkSelectionInIdle));
		initSelChangeTrap(editor);
		array<SelectionChangedReceiver&&>&& subscribers;
		auto fnd = selChangeSubscribers.find(editor.self);
		if (fnd.isEnd()) {
			&&subscribers = array<SelectionChangedReceiver&&>();
			selChangeSubscribers.insert(editor.self, subscribers);
		} else
			&&subscribers = fnd.value;
		subscribers.insertLast(receiver);
	}
	// Отписка от изменений в окне редактора
	void _unsubsribeFromSelChange(ITextEditor&& editor, SelectionChangedReceiver& receiver) {
		auto fnd = selChangeSubscribers.find(editor.self);
		if (!fnd.isEnd()) {
			for (uint i = 0; i < fnd.value.length; i++) {
				if (fnd.value[i] is receiver) {
					fnd.value.removeAt(i);
					break;
				}
			}
			if (fnd.value.length == 0) {
				selChangeSubscribers.remove(editor.self);
				if (selChangeSubscribers.count() == 0)
					disableSelChangeTrap();
			}
		}
	}
	// Подписка на изменения в тексте документа
	void _subscribeToTextChange(TextManager& tm, TextModifiedReceiver& receiver) {
		initTextModifiedTraps();
		array<TextModifiedReceiver&&>&& subscribers;
		auto fnd = textChangeSubscribers.find(tm.self);
		if (fnd.isEnd()) {
			&&subscribers = array<TextModifiedReceiver&&>();
			textChangeSubscribers.insert(tm.self, subscribers);
		} else
			&&subscribers = fnd.value;
		subscribers.insertLast(receiver);
	}
	// Отписка от изменений в тексте документа
	void _unsubsribeFromTextChange(TextManager& tm, TextModifiedReceiver& receiver) {
		auto fnd = textChangeSubscribers.find(tm.self);
		if (!fnd.isEnd()) {
			for (uint i = 0; i < fnd.value.length; i++) {
				if (fnd.value[i] is receiver) {
					fnd.value.removeAt(i);
					break;
				}
			}
			if (fnd.value.length == 0) {
				textChangeSubscribers.remove(tm.self);
				if (textChangeSubscribers.count() == 0)
					disableTextModifiedTrap();
			}
		}
	}
	// Получение подписчиков
	array<SelectionChangedReceiver&&>&& _getSelChangeSubscribers(ITextEditor& editor) {
		auto fnd = selChangeSubscribers.find(editor.self);
		return !fnd.isEnd() ? fnd.value : null;
	}
	array<TextModifiedReceiver&&>&& _getTextChangeSubscribers(TextManager& tm) {
		auto fnd = textChangeSubscribers.find(tm.self);
		return !fnd.isEnd() ? fnd.value : null;
	}
	// Количество зарегистрированных редакторов
	uint count() {
		return editors.length;
	}
	ComEditorInfo&& editor(uint idx) {
		if (idx >= editors.length)
			return null;
		return ComEditorInfo(editors[idx]);
	}
	// Назначение активного редактора для текстового расширения
	bool setActiveEditor(const string& extName, const string& editorName) {
		auto fnd = editorForExtNames.find(extName);
		if (!fnd.isEnd()) {
			array<string>&& names = fnd.value.extGuids();
			for (uint k = 0; k < names.length; k++)
				editorForExtGuids.remove(names[k]);
			editorForExtNames.remove(extName);
		}
		if (editorName.isEmpty())
			return true;
		for (uint i = 0; i < editors.length; i++) {
			EditorInfo&& ei = editors[i];
			if (ei.name() == editorName && ei.extention() == extName) {
				ei.activate();
				array<string>&& exts = ei.extGuids();
				for (uint k = 0; k < exts.length; k++)
					editorForExtGuids.insert(exts[k], ei);
				editorForExtNames.insert(extName, ei);
				return true;
			}
		}
		return false;
	}
	void setup(const string& editorName) {
		if (!editorName.isEmpty()) {
			for (uint i = 0; i < editors.length; i++) {
				EditorInfo&& ei = editors[i];
				if (ei.name() == editorName) {
					ei.doSetup();
					return;
				}
			}
		}
	}
};
EditorsManager editorsManager;

TrapVirtualStdCall trSSN;
TrapVirtualStdCall trSCP;
TrapVirtualStdCall trSTCP;
TrapVirtualStdCall trSS;
TrapVirtualStdCall trGetListPos;
TrapSwap trSetSelText;
TrapSwap trClearTextSel;

void initSelChangeTrap(ITextEditor&& ted) {
	if (trSSN.state == trapNotActive) {
		trSSN.setTrap(ted, ITextEditor_setSelectionNull, setSelectionNull_trap);
		trSCP.setTrap(ted, ITextEditor_setCaretPosition, setCaretPosition_trap);
		trSTCP.setTrap(ted, ITextEditor_scrollToCaretPos, scrollToCaretPos_trap);
		trSS.setTrap(ted, ITextEditor_setSelection, setSelection_trap);
		ITEIntelliSence&& teis = ted.unk;
		if (teis !is null) //вылетает в окне сравнения модулей
			trGetListPos.setTrap(teis, ITEIntelliSence_getContextListPos, getContextListPos_trap);
	} else if (trSSN.state == trapDisabled) {
		trSSN.swap();
		trSCP.swap();
		trSTCP.swap();
		trSS.swap();
		if (trGetListPos.state == trapDisabled) 
			trGetListPos.swap();
	}
}

void disableSelChangeTrap() {
	if (trSSN.state == trapEnabled) {
		trSSN.swap();
		trSCP.swap();
		trSTCP.swap();
		trSS.swap();
	}
}

void initTextModifiedTraps() {
	if (trSetSelText.state == trapNotActive) {
	#if ver<8.3
		string dll = "core82.dll";
	#else
		string dll = "core83.dll";
	#endif
		trSetSelText.setTrapByName(dll, "?setSelectText@TextManager@core@@QAEXPB_W_N@Z", asCALL_THISCALL, setSelectText_trap);
		trClearTextSel.setTrapByName(dll, "?clearTextSelection@TextManager@core@@QAEXXZ", asCALL_THISCALL, clearTextSelection_trap);
	} else if (trSetSelText.state == trapDisabled) {
		trSetSelText.swap();
		trClearTextSel.swap();
	}
}

void disableTextModifiedTrap() {
	if (trSetSelText.state == trapEnabled) {
		trSetSelText.swap();
		trClearTextSel.swap();
	}
}

void notifyTextChange(TextManager& tm, const string& text) {
	auto subscribers = editorsManager._getTextChangeSubscribers(tm);
	if (subscribers !is null) {
		TextPosition t1, t2;
		tm.getSelectRange(t1, t2);
		if (!(t1 == t2 && text.isEmpty())) {
			for (uint i = 0; i < subscribers.length; i++)
				subscribers[i].onTextModified(tm, t1, t2, text);
		}
	}
}

void setSelectText_trap(TextManager& tm, int_ptr pText, bool b) {
	notifyTextChange(tm, stringFromAddress(pText));
	trSetSelText.swap();
	tm.setSelectText(pText, b);
	trSetSelText.swap();
}

void clearTextSelection_trap(TextManager& tm) {
	notifyTextChange(tm, string());
	trClearTextSel.swap();
	tm.clearTextSelection();
	trClearTextSel.swap();
}

void notifyChangeSelection(ITextEditor& ted) {
	auto subscribers = editorsManager._getSelChangeSubscribers(ted);
	if (subscribers !is null) {
		TextPosition t1, t2;
		ted.getSelection(t1, t2);
		//Message("notify sel change " + tpstr(t1) + " " + tpstr(t2));
		for (uint i = 0; i < subscribers.length; i++)
			subscribers[i].onSelectionChanged(ted, t1, t2);
	}
}

funcdef void ITextEditorV(ITextEditor&);

void setSelectionNull_trap(ITextEditor& pEd) {
	ITextEditorV&& orig;
	trSSN.getOriginal(&&orig);
	orig(pEd);
	notifyChangeSelection(pEd);
}

funcdef void SCP_func(ITextEditor&, const TextPosition&, bool);
void setCaretPosition_trap(ITextEditor& pEd, const TextPosition& tp, bool bInScreenCoords) {
	//Message("Set caret " + tpstr(tp) + " " + bInScreenCoords);
	SCP_func&& orig;
	trSCP.getOriginal(&&orig);
	orig(pEd, tp, bInScreenCoords);
	notifyChangeSelection(pEd);
}

funcdef void SS_func(ITextEditor&, const TextPosition&, const TextPosition&, bool, bool);
void setSelection_trap(ITextEditor& pEd, const TextPosition& tpStart, const TextPosition& tpStop, bool bCaretToStart, bool bInScreenCoords) {
	SS_func&& orig;
	trSS.getOriginal(&&orig);
	orig(pEd, tpStart, tpStop, bCaretToStart, bInScreenCoords);
	notifyChangeSelection(pEd);
}

void scrollToCaretPos_trap(ITextEditor& pEd) {
	ITextEditorV&& orig;
	trSTCP.getOriginal(&&orig);
	orig(pEd);
	auto subscribers = editorsManager._getSelChangeSubscribers(pEd);
	if (subscribers !is null) {
		for (uint i = 0; i < subscribers.length; i++)
			subscribers[i].onScrollToCaretPos(pEd);
	}
}

funcdef void ContextListPos_func(ITEIntelliSence&, Point&, uint&);
void getContextListPos_trap(ITEIntelliSence& teis, Point& caretPos, uint& lineHeight) {
	ITextEditor&& ted = teis.unk;
	if (ted !is null) {
		auto subscribers = editorsManager._getSelChangeSubscribers(ted);
		if (subscribers !is null) {
			for (uint k = 0; k < subscribers.length; k++) {
				if (subscribers[k].getCaretPosForIS(teis, caretPos, lineHeight))
					return;
			}
		}
	}
	ContextListPos_func&& orig;
	trGetListPos.getOriginal(&&orig);
	orig(teis, caretPos, lineHeight);
}
